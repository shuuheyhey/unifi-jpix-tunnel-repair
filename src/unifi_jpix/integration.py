"""Guarded migration to the enrolled UniFi WAN, with timed runtime recovery."""
import copy
from dataclasses import replace
import json
from pathlib import Path
import shlex
import time

from .core import Config, FIREWALL_TAG, ForeignConflict, JpixError, MutationError, Reconciler, Runner, StateStore, TUNNEL_ALIAS, _reason_code
from .managed import ManagedReconciler, controlled, desired_fields, patch_fields
from .router import RouterRecovery, bindings, binding_patch

UNITS = ('unifi-jpix-reconcile.timer', 'unifi-jpix-event-monitor.service',
         'unifi-jpix-udapi.path', 'unifi-jpix-udapi-reconcile.service',
         'unifi-jpix-reconcile.service')
RECOVERY_UNIT = 'unifi-jpix-managed-recovery'


def inventory(runner):
    result = []
    for binary in ('iptables', 'ip6tables'):
        table = None
        output = runner.run([binary + '-save']).stdout
        for line in output.splitlines():
            if line.startswith('*'):
                table = line[1:]
            elif line == 'COMMIT':
                table = None
            elif line.startswith('-A '):
                fields = shlex.split(line)
                if '--comment' in fields and fields[fields.index('--comment') + 1] == FIREWALL_TAG:
                    if table is None:
                        raise ForeignConflict('migration firewall inventory is invalid')
                    result.append([binary, table, *fields[1:]])
    return result


def allowed_rules(record):
    original = record['firewall']
    native = []
    for row in original:
        if row[0] == 'iptables' and row[1] == 'filter':
            continue  # UniFi already dispatches the real WAN to its own policy.
        native.append([record['native_name'] if token == record['standalone_name'] else token for token in row])
    return {tuple(row) for row in original + native}


def clear_rules(runner, record):
    current = inventory(runner)
    if any(tuple(row) not in allowed_rules(record) for row in current):
        raise ForeignConflict('migration found unknown project firewall resources')
    for binary, table, chain, *rule in current:
        runner.run([binary, '-w', '5', '-t', table, '-D', chain, *rule])


def _stop(runner):
    runner.run(['systemctl', 'stop', *UNITS])


def _start(runner):
    runner.run(['systemctl', 'start', 'unifi-jpix-reconcile.timer',
                'unifi-jpix-event-monitor.service', 'unifi-jpix-udapi.path'])


def recover(root, runner=None):
    runner = runner or Runner()
    state = StateStore(root)
    record_path = state.state_dir / 'managed-migration.json'
    record = state.read(record_path)
    if not record or record['status'] in {'confirmed', 'recovered'}:
        return {'status': 'no-recovery-needed'}
    _stop(runner)
    with state.lock():
        record = state.read(record_path)
        if record['status'] in {'confirmed', 'recovered'}:
            _start(runner)
            return {'status': 'no-recovery-needed'}
        config = Config.load(root / 'config-v2.json')
        managed = ManagedReconciler(replace(config, wan_integration='unifi-managed'), root, runner)
        interfaces, native, name, _ = managed.configuration()
        if name != record['native_name']:
            raise ForeignConflict('recovery WAN identity changed')
        now = controlled(native)
        if any(value not in (record['native_original'][key], record['native_desired'][key]) for key, value in now.items()):
            raise ForeignConflict('recovery refuses concurrent WAN changes')
        clear_rules(runner, record)
        restored = patch_fields(interfaces, name, record['native_original'])
        managed.put_interfaces(interfaces, restored)
        # Restore only monitor flags, preserving all other live services.
        router = RouterRecovery(config, runner, managed.allocate_resources(), state)
        current_services = router.services()
        router._put(current_services, binding_patch(current_services, record['monitor_bindings']))
        time.sleep(10)  # UDAPI asynchronously regenerates its firewall.
        table = str(record['runtime']['resources']['route_table'])
        default = runner.run(['ip', '-4', 'route', 'show', 'table', table, 'default'], check=False).stdout.strip()
        if default:
            if default.split()[:3] == ['default', 'dev', record['standalone_name']]:
                pass  # Failure occurred before the old device was removed.
            elif default.split()[:3] == ['default', 'dev', name]:
                runner.run(['ip', '-4', 'route', 'del', 'table', table, 'default', 'dev', name])
            else:
                raise ForeignConflict('recovery default route changed ownership')
        state.write(root / 'config-v2.json', record['configuration'])
        state.write(state.runtime_path, record['runtime'])
        (state.state_dir / 'managed-wan.json').unlink(missing_ok=True)
    result = Reconciler(Config.load(root / 'config-v2.json'), root, runner).reconcile()
    if result['status'] != 'healthy':
        raise MutationError('standalone-recovery-health-failed')
    record['status'] = 'recovered'
    state.write(record_path, record)
    runner.run(['systemctl', 'stop', record.get('recovery_unit', RECOVERY_UNIT) + '.timer'], check=False)
    _start(runner)
    return {'status': 'recovered-standalone'}


def activate(root, runner=None):
    runner = runner or Runner()
    state = StateStore(root)
    path = root / 'config-v2.json'
    config = Config.load(path)
    if config.wan_integration != 'standalone':
        raise ForeignConflict('integration is already enabled')
    old = Reconciler(config, root, runner)
    capabilities, resources, pending = old.plan()
    if pending or old.status()['status'] != 'healthy':
        raise ForeignConflict('migration requires a healthy standalone baseline')
    managed = ManagedReconciler(replace(config, wan_integration='unifi-managed'), root, runner)
    _, native, name, _ = managed.configuration()
    if runner.run(['cat', f'/sys/class/net/{config.tunnel_name}/ifalias']).stdout.strip() != TUNNEL_ALIAS:
        raise ForeignConflict('standalone tunnel ownership is unavailable')
    record_path = state.state_dir / 'managed-migration.json'
    prior = state.read(record_path)
    if prior and prior['status'] not in {'recovered'}:
        raise ForeignConflict('a migration record already exists')
    if prior:
        runner.run(['systemctl', 'stop', prior.get('recovery_unit', RECOVERY_UNIT) + '.timer'], check=False)
    record = {
        'schema': 1, 'status': 'pending', 'recovery_unit': RECOVERY_UNIT + '-' + str(time.time_ns()),
        'configuration': json.loads(path.read_text()),
        'runtime': state.read(state.runtime_path), 'native_name': name,
        'standalone_name': config.tunnel_name, 'native_original': controlled(native),
        'native_desired': desired_fields(native, config, capabilities),
        'monitor_bindings': bindings(old.router.services()), 'firewall': inventory(runner),
    }
    # The timer invokes this immutable release even if current later changes.
    cli = root.joinpath('current/bin/unifi-jpix').resolve()
    state.write(record_path, record)
    runner.run(['systemd-run', '--unit=' + record['recovery_unit'], '--on-active=10m',
                str(cli), '--root', str(root), 'integrate-wan', '--recover'])
    try:
        _stop(runner)
        with state.lock():
            if old.plan()[2]:
                raise ForeignConflict('standalone changed before migration')
            updated = copy.deepcopy(record['configuration'])
            updated['integration'] = {'mode': 'unifi-managed'}
            state.write(path, updated)
            clear_rules(runner, record)
            runner.run(['ip', '-6', 'tunnel', 'del', config.tunnel_name])
        result = ManagedReconciler(Config.load(path), root, runner).reconcile()
        record['status'] = 'awaiting-confirmation'
        state.write(record_path, record)
        _start(runner)
        return {**result, 'migration': 'awaiting-confirmation', 'automatic_recovery_seconds': 600}
    except Exception as exc:
        record['failure_reason'] = _reason_code(exc) if isinstance(exc, JpixError) else 'operation-failed'
        state.write(record_path, record)
        try:
            recover(root, runner)
        except Exception as recovery_error:
            raise MutationError('managed-migration-recovery-failed') from recovery_error
        raise MutationError('managed-migration-failed-restored-standalone') from exc


def confirm(root, runner=None):
    runner = runner or Runner()
    state = StateStore(root)
    record_path = state.state_dir / 'managed-migration.json'
    record = state.read(record_path)
    if not record or record['status'] != 'awaiting-confirmation':
        raise ForeignConflict('no migration awaits confirmation')
    config = Config.load(root / 'config-v2.json')
    if config.wan_integration != 'unifi-managed':
        raise ForeignConflict('managed configuration is not active')
    result = ManagedReconciler(config, root, runner).reconcile()
    # Marker first: a timer racing with cancellation will safely do nothing.
    with state.lock():
        record = state.read(record_path)
        if record['status'] != 'awaiting-confirmation' or Config.load(root / 'config-v2.json').wan_integration != 'unifi-managed':
            raise ForeignConflict('recovery raced with confirmation')
        record['status'] = 'confirmed'
        state.write(record_path, record)
    runner.run(['systemctl', 'stop', record.get('recovery_unit', RECOVERY_UNIT) + '.timer'])
    return {**result, 'migration': 'confirmed'}
