"""Opt-in UDAPI single-WAN compatibility adapter.

No tunnel or UniFi route is mutated. Only four monitor bind flags are changed
through UDAPI, preserving all other services. Unknown layouts fail closed.
"""
from __future__ import annotations

import copy
import json
import re

from .core import Action, FIREWALL_TAG, ForeignConflict, MutationError, PrerequisiteUnavailable

FLAGS = ('bindAddress', 'bindDomainResolution', 'bindInterface', 'bindRoutingTable')
UDAPI_STATE = '/data/udapi-config/ubios-udapi-server/ubios-udapi-server.state'


def topology(services):
    try:
        wan = services['wanFailover']
        interfaces = wan['wanInterfaces']
        groups = wan['failoverGroups']
        if wan['enabled'] is not True or len(interfaces) != 1 or len(groups) != 1:
            raise ValueError
        interface = interfaces[0]
        name, table = interface['interface'], interface['routingTable']
        if not re.fullmatch(r'ip6tnl[0-9]+', name) or type(table) is not int or table <= 0:
            raise ValueError
        if groups[0]['algorithm'] != 'single' or groups[0]['interfaces'] != [name]:
            raise ValueError
        monitors = interface['monitors']
        if not monitors or len({m['id'] for m in monitors}) != len(monitors):
            raise ValueError
        if any(type(m['id']) is not int or any(type(m[f]) is not bool for f in FLAGS) for m in monitors):
            raise ValueError
        return name, table
    except (KeyError, TypeError, ValueError, IndexError) as exc:
        raise ForeignConflict('single-WAN monitor contract is unsupported') from exc


def bindings(services):
    topology(services)
    return {str(m['id']): {f: m[f] for f in FLAGS}
            for m in services['wanFailover']['wanInterfaces'][0]['monitors']}


def binding_patch(services, desired):
    result = copy.deepcopy(services)
    current = bindings(result)
    wanted = {key: dict.fromkeys(FLAGS, desired) for key in current} if type(desired) is bool else desired
    if set(wanted) != set(current) or any(set(v) != set(FLAGS) or any(type(x) is not bool for x in v.values()) for v in wanted.values()):
        raise ForeignConflict('monitor identities changed')
    for m in result['wanFailover']['wanInterfaces'][0]['monitors']:
        m.update(wanted[str(m['id'])])
    return result


class RouterRecovery:
    def __init__(self, config, runner, resources, state=None, *, bind_monitors=False):
        self.config, self.runner, self.resources, self.state = config, runner, resources, state
        self.mark = None
        self.identity = None
        self.record = None
        self.bind_monitors = bind_monitors

    def services(self):
        result = self.runner.run(['cat', UDAPI_STATE], check=False)
        try:
            if result.returncode:
                raise ValueError
            services = json.loads(result.stdout)['services']
            topology(services)
            return services
        except (ValueError, KeyError, TypeError) as exc:
            raise PrerequisiteUnavailable('UDAPI configuration unavailable') from exc

    def _inspect_rules(self, services):
        name, table = topology(services)
        rules = self.runner.run(['ip', '-4', 'rule', 'show']).stdout.splitlines()
        main = [line.split() for line in rules if re.search(r'\blookup (main|254)\b', line)]
        # This is a capability contract for the observed UDAPI layout, not a
        # universal policy-routing fallback. In particular, main precedes us.
        if main != [['32000:', 'from', 'all', 'lookup', 'main']]:
            raise ForeignConflict('router main-table priority is unsupported')
        default = self.runner.run(['ip', '-4', 'route', 'show', 'table', 'main', 'default'], check=False)
        if default.returncode or default.stdout.strip():
            raise ForeignConflict('router main-table default is unsupported')
        candidates = []
        for line in rules:
            match = re.fullmatch(r'(\d+):\s+from all fwmark (0x[0-9a-f]+/0x[0-9a-f]+) lookup (\S+)', line)
            if match and match[3] in {str(table), f'{table}.{name}'}:
                candidates.append(match)
        if len(candidates) != 1 or int(candidates[0][1]) <= 32001:
            raise ForeignConflict('WAN mark policy is ambiguous')
        self.mark = candidates[0][2]
        self.identity = {'interface': name, 'wan_table': table, 'mark': self.mark,
                         'route_table': self.resources.route_table,
                         'dns_priority': self.resources.rule_priority_base - 1, 'router_priority': 32001}
        if not 1 < self.identity['dns_priority'] < 32000:
            raise ForeignConflict('router DNS priority is unsupported')
        return rules

    def rule_specs(self):
        return [
            (32001, ('iif', 'lo', 'lookup', str(self.resources.route_table))),
            (self.resources.rule_priority_base - 1,
             ('iif', 'lo', 'fwmark', self.mark, 'lookup', str(self.resources.route_table))),
        ]

    def _matches(self, line, pref, spec):
        # iproute2 prints fwmark before iif regardless of insertion order.
        wanted = {spec[i]: spec[i + 1] for i in range(0, len(spec), 2)}
        tokens = line.split()
        if tokens[:3] != [f'{pref}:', 'from', 'all'] or len(tokens[3:]) != len(spec):
            return False
        return {tokens[i]: tokens[i + 1] for i in range(3, len(tokens), 2)} == wanted

    def plan(self):
        services = self.services()
        rules = self._inspect_rules(services)
        actions = []
        if self.state:
            path = self.state.state_dir / 'router-recovery.json'
            self.record = self.state.read(path)
            if self.record and self.record.get('identity') != self.identity:
                raise ForeignConflict('router recovery ownership changed')
            if not self.record:
                record = {'schema': 1, 'identity': self.identity, 'original_bindings': bindings(services)}
                actions.append(Action('router-recovery-enroll', ('state',),
                                      apply_callback=lambda: self.state.write(path, record),
                                      undo_callback=lambda: path.unlink(missing_ok=True)))
        for pref, spec in self.rule_specs():
            matches = [line for line in rules if line.startswith(f'{pref}:')]
            if matches and (len(matches) != 1 or not self._matches(matches[0], pref, spec)):
                raise ForeignConflict('router recovery priority is occupied')
            if not matches:
                suffix = ('pref', str(pref), *spec)
                actions.append(Action('router-local-policy-rule-missing',
                                      ('ip', '-4', 'rule', 'add', *suffix),
                                      ('ip', '-4', 'rule', 'del', *suffix)))
        desired = binding_patch(services, self.bind_monitors)
        if services != desired:
            actions.append(Action('wan-monitor-binding-drift', ('udapi-monitor',),
                                  apply_callback=lambda: self._put(services, desired),
                                  undo_callback=lambda: self._put(desired, services)))
        return actions

    def _put(self, expected, desired):
        current = self.services()
        if current == desired:
            return
        if current != expected:
            raise ForeignConflict('UDAPI configuration changed concurrently')
        # No timeout/notification: an uncertain PUT must not be retried blindly.
        result = self.runner.input_json(['ubios-udapi-client', '-r', 'PUT', '/services', '@/dev/stdin'], desired)
        try:
            response = json.loads(result.stdout)
        except ValueError as exc:
            raise MutationError('monitor-update-unconfirmed') from exc
        if result.returncode or (isinstance(response, dict) and response.get('statusCode', 200) >= 400):
            raise MutationError('monitor-update-failed')
        if self.services() != desired:
            raise MutationError('monitor-update-unconfirmed')

    def dns_snat_rule(self):
        if self.mark is None:
            raise ForeignConflict('router mark is not verified')
        return ('-o', self.config.tunnel_name, '-p', 'udp', '--dport', '53',
                '-m', 'mark', '--mark', self.mark, '-m', 'addrtype', '--src-type', 'LOCAL',
                '-m', 'comment', '--comment', FIREWALL_TAG, '-j', 'SNAT', '--to-source', self.config.static_ipv4)

    def health_check(self):
        for mark in (None, self.mark):
            command = ['ip', '-4', 'route', 'get', '1.1.1.1']
            if mark:
                command += ['mark', mark.split('/')[0]]
            result = self.runner.run(command, check=False)
            tokens = result.stdout.split()
            if result.returncode or 'dev' not in tokens or tokens[tokens.index('dev') + 1] != self.config.tunnel_name:
                raise MutationError('router-route-health-failed')
        if self.runner.run(['ping', '-4', '-c', '2', '-W', '3', '1.1.1.1'], check=False).returncode:
            raise MutationError('router-connectivity-health-failed')
        live = self.runner.run(['ubios-udapi-client', '-r', 'GET', '/services'], check=False)
        try:
            services = json.loads(live.stdout)
            if live.returncode or topology(services) != (self.identity['interface'], self.identity['wan_table']):
                raise ValueError
            if any(value != self.bind_monitors for monitor in bindings(services).values() for value in monitor.values()):
                raise ValueError
        except (ValueError, ForeignConflict) as exc:
            raise MutationError('monitor-binding-health-failed') from exc

    def deactivate(self):
        services = self.services()
        rules = self._inspect_rules(services)
        record = self.state.read(self.state.state_dir / 'router-recovery.json')
        if not record or record.get('identity') != self.identity:
            raise ForeignConflict('router recovery ownership unavailable')
        # Validate every owned rule before performing any removal.
        present = []
        for pref, spec in self.rule_specs():
            matches = [line for line in rules if line.startswith(f'{pref}:')]
            if matches and (len(matches) != 1 or not self._matches(matches[0], pref, spec)):
                raise ForeignConflict('router recovery rule changed ownership')
            if matches:
                present.append((pref, spec))
        desired = binding_patch(services, record['original_bindings'])
        self._put(services, desired)
        for pref, spec in present:
            self.runner.run(['ip', '-4', 'rule', 'del', 'pref', str(pref), *spec])
