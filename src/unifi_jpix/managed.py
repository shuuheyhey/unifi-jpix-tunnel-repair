"""Explicitly enrolled UniFi-managed single-WAN integration.

UniFi owns interface identity, native routes and policy. This adapter corrects
the enrolled tunnel's IPv4/selector/MTU/MSS fields through UDAPI, then repairs
its kernel endpoint because the observed API cannot select a static endpoint.
Project routing and tagged rules remain separately owned. No vendor file or
controller database is patched.
"""
import copy
from dataclasses import replace
import ipaddress
import json

from .core import (Action, ForeignConflict, MutationError, PrerequisiteUnavailable,
                   Reconciler, _token_after)
from .router import RouterRecovery, UDAPI_STATE, topology

CAPABILITY_VERSION = 2


def controlled(interface):
    return {'addresses': copy.deepcopy(interface['addresses']),
            'localAddress': copy.deepcopy(interface['tunnel']['localAddress']),
            'remoteAddress': interface['tunnel']['remoteAddress'],
            'mtu': interface['status']['mtu'],
            'mssClamping': copy.deepcopy(interface['ipv4']['mssClamping'])}


def patch_fields(interfaces, name, fields):
    result = copy.deepcopy(interfaces)
    matches = [i for i in result if i.get('identification', {}).get('id') == name]
    if len(matches) != 1:
        raise ForeignConflict('managed WAN identity is ambiguous')
    row = matches[0]
    row['addresses'] = copy.deepcopy(fields['addresses'])
    row['tunnel']['localAddress'] = copy.deepcopy(fields['localAddress'])
    row['tunnel']['remoteAddress'] = fields['remoteAddress']
    row['status']['mtu'] = fields['mtu']
    row['ipv4']['mssClamping'] = copy.deepcopy(fields['mssClamping'])
    return result


def desired_fields(interface, config, capabilities):
    fields = controlled(interface)
    # AddressSelectorStatic exists in libudapi's schema, but the observed UDM
    # runtime rejects it as unimplemented. Keep its supported WAN selector and
    # reconcile the contract endpoint in the kernel after UDAPI settles.
    fields['localAddress'] = {'source': 'interface', 'id': capabilities.wan_interface, 'ipVersion': 'v6'}
    fields['remoteAddress'] = config.br_ipv6
    fields['addresses'] = [{'cidr': f'{config.static_ipv4}/32', 'eui64': False,
                            'origin': None, 'type': 'static', 'version': 'v4'}]
    fields['mtu'] = config.tunnel_mtu
    fields['mssClamping'] = {'mssClampSize': config.tcp_mss}
    return fields


class ManagedReconciler(Reconciler):
    def configuration(self):
        result = self.runner.run(['cat', UDAPI_STATE], check=False)
        try:
            data = json.loads(result.stdout)
            name, table = topology(data['services'])
            interfaces = data['interfaces']
            matches = [i for i in interfaces if i['identification']['id'] == name]
            if result.returncode or len(matches) != 1:
                raise ValueError
            native = matches[0]
            if native['identification']['type'] != 'tunnel' or native['tunnel']['mode'] != 'ip6tnl':
                raise ValueError
            if native['status']['enabled'] is not True or native['tunnel']['remoteAddressFallbackMapping']:
                raise ValueError
            if native['tunnel']['remoteAddress'] != self.config.br_ipv6:
                raise ForeignConflict('managed WAN BR changed outside enrollment')
            if len(native['addresses']) != 1 or native['addresses'][0]['version'] != 'v4' or native['addresses'][0]['type'] != 'static':
                raise ValueError
            ipaddress.IPv4Interface(native['addresses'][0]['cidr'])
            controlled(native)
            return interfaces, native, name, table
        except (KeyError, ValueError, TypeError, IndexError) as exc:
            raise PrerequisiteUnavailable('managed WAN capability unavailable') from exc

    def put_interfaces(self, expected, desired):
        current, _, _, _ = self.configuration()
        if current == desired:
            return
        if current != expected:
            raise ForeignConflict('interfaces changed concurrently')
        result = self.runner.input_json(['ubios-udapi-client', '-r', 'PUT', '/interfaces', '@/dev/stdin'], desired)
        try:
            response = json.loads(result.stdout)
            if result.returncode or isinstance(response, dict) and response.get('statusCode', 200) >= 400:
                raise ValueError
            if self.configuration()[0] != desired:
                raise ValueError
        except (ValueError, PrerequisiteUnavailable) as exc:
            raise MutationError('managed-wan-update-unconfirmed') from exc

    def plan(self):
        capabilities = self.discover()
        resources = self.allocate_resources()
        interfaces, native, name, table = self.configuration()
        self.config = replace(self.config, tunnel_name=name)
        record_path = self.state.state_dir / 'managed-wan.json'
        record = self.state.read(record_path)
        identity = {'interface': name, 'table': table}
        fields = controlled(native)
        desired = desired_fields(native, self.config, capabilities)
        actions = []
        if record:
            if record.get('identity') != identity:
                raise ForeignConflict('managed WAN enrollment changed')
            allowed_addresses = [record['original']['addresses'], desired['addresses']]
            runtime = self.state.read(self.state.runtime_path) or {}
            if runtime.get('static_ipv4'):
                old = copy.deepcopy(desired['addresses'])
                old[0]['cidr'] = runtime['static_ipv4'] + '/32'
                allowed_addresses.append(old)
            if fields['addresses'] not in allowed_addresses:
                raise ForeignConflict('managed WAN IPv4 ownership changed')
        else:
            selector = native['tunnel']['localAddress']
            if selector.get('source') != 'interface' or selector.get('ipVersion') != 'v6':
                raise ForeignConflict('managed WAN requires explicit migration enrollment')
            record = {'schema': 1, 'identity': identity, 'original': fields}
            actions.append(Action('managed-wan-enroll', ('state',),
                                  apply_callback=lambda: self.state.write(record_path, record),
                                  undo_callback=lambda: record_path.unlink(missing_ok=True)))
        self.router = RouterRecovery(self.config, self.runner, resources, self.state, bind_monitors=True)
        router_actions = self.router.plan()
        if not self._address_exists(capabilities.wan_interface, capabilities.local_endpoint + '/128', 6):
            spec = ('ip', '-6', 'address')
            suffix = (capabilities.local_endpoint + '/128', 'dev', capabilities.wan_interface)
            actions.append(Action('endpoint-address-missing', (*spec, 'add', *suffix), (*spec, 'del', *suffix)))
        if fields != desired:
            updated = patch_fields(interfaces, name, desired)
            actions.append(Action('managed-wan-config-drift', ('udapi-interface',),
                                  apply_callback=lambda: self.put_interfaces(interfaces, updated),
                                  undo_callback=lambda: self.put_interfaces(updated, interfaces)))
        else:
            tunnel = self.runner.run(['ip', '-d', '-6', 'tunnel', 'show', name], check=False)
            if tunnel.returncode or not tunnel.stdout.strip():
                raise PrerequisiteUnavailable('UniFi managed tunnel is not ready')
            old_local, old_remote = (_token_after(tunnel.stdout, k) for k in ('local', 'remote'))
            mode = tunnel.stdout.split()[1]
            if mode not in {'any/ipv6', 'ip/ipv6', 'ipip6/ipv6'}:
                raise ForeignConflict('managed kernel tunnel mode is unsupported')
            old_mode = 'any' if mode == 'any/ipv6' else 'ipip6'
            if old_local != capabilities.local_endpoint or old_remote != self.config.br_ipv6 or old_mode != 'ipip6':
                actions.append(Action('managed-wan-runtime-drift',
                                      ('ip', '-6', 'tunnel', 'change', name, 'mode', 'ipip6', 'local', capabilities.local_endpoint, 'remote', self.config.br_ipv6),
                                      ('ip', '-6', 'tunnel', 'change', name, 'mode', old_mode, 'local', old_local, 'remote', old_remote)))
            if not self._address_exists(name, self.config.static_ipv4 + '/32', 4):
                raise PrerequisiteUnavailable('managed WAN address has not converged')
        actions.extend(self._route_rule_actions(resources))
        actions.extend(self._firewall_actions(capabilities))
        actions.extend(self._endpoint_cleanup_actions(capabilities))
        actions.extend(router_actions)
        return capabilities, resources, actions

    def _health_check(self, capabilities, resources):
        super()._health_check(capabilities, resources)
        _, native, name, _ = self.configuration()
        if controlled(native) != desired_fields(native, self.config, capabilities):
            raise MutationError('managed-wan-config-health-failed')
        if not self._address_exists(name, self.config.static_ipv4 + '/32', 4):
            raise MutationError('managed-wan-address-health-failed')
        kernel = self.runner.run(['ip', '-d', '-6', 'tunnel', 'show', name]).stdout
        if _token_after(kernel, 'local') != capabilities.local_endpoint or _token_after(kernel, 'remote') != self.config.br_ipv6 or kernel.split()[1] not in {'ip/ipv6', 'ipip6/ipv6'}:
            raise MutationError('managed-wan-endpoint-health-failed')
        result = self.runner.run(['curl', '-4', '--interface', 'if!' + name, '--silent', '--max-time', '10',
                                  '--output', '/dev/null', '--write-out', '%{http_code}',
                                  'https://www.youtube.com/generate_204'], check=False)
        if result.returncode or result.stdout.strip() != '204':
            raise MutationError('managed-wan-bound-https-health-failed')

    def deactivate(self):
        raise ForeignConflict('managed WAN requires explicit migration recovery')
