import copy
from dataclasses import replace
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from unifi_jpix.core import Config, ConfigError, ForeignConflict, MutationError, PrerequisiteUnavailable
from unifi_jpix.managed import ManagedReconciler, controlled, desired_fields, patch_fields
from unifi_jpix.integration import allowed_rules, clear_rules, recover
from unifi_jpix.router import UDAPI_STATE
from test_core import BASE_CONFIG, FakeRunner
from test_router import RULES, SERVICES

NATIVE = {
    'identification': {'id': 'ip6tnl1', 'type': 'tunnel'},
    'addresses': [{'cidr': '192.0.0.2/29', 'eui64': False, 'origin': None, 'type': 'static', 'version': 'v4'}],
    'tunnel': {'id': 1, 'mode': 'ip6tnl', 'remoteAddress': BASE_CONFIG['br_ipv6'],
               'localAddress': {'source': 'interface', 'id': 'eth9', 'ipVersion': 'v6'}, 'remoteAddressFallbackMapping': []},
    'status': {'mtu': 1460, 'enabled': True, 'speed': 'auto', 'comment': 'retain'},
    'ipv4': {'cos': 0, 'dhcpOptions': [], 'mssClamping': {'mssClampSize': 1420}},
}


class ManagedRunner(FakeRunner):
    def __init__(self):
        super().__init__(rules=RULES)
        self.data = {'interfaces': [copy.deepcopy(NATIVE), {'identification': {'id': 'br0'}, 'preserve': 'sentinel'}],
                     'services': copy.deepcopy(SERVICES)}

    def run(self, command, *, check=True):
        if tuple(command) == ('cat', UDAPI_STATE):
            return subprocess.CompletedProcess(command, 0, json.dumps(self.data), '')
        if tuple(command[:6]) == ('ip', '-4', 'route', 'show', 'table', '10000'):
            return subprocess.CompletedProcess(command, 0, 'default dev ip6tnl1\n', '')
        return super().run(command, check=check)

    def input_json(self, command, payload):
        self.commands.append(tuple(command))
        self.data['interfaces'] = copy.deepcopy(payload)
        return subprocess.CompletedProcess(command, 0, '[]', '')


class ManagedTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.raw = copy.deepcopy(BASE_CONFIG)
        self.raw.update(router_recovery={'enabled': True}, integration={'mode': 'unifi-managed'})
        self.path = self.root / 'config-v2.json'
        self.path.write_text(json.dumps(self.raw))
        self.path.chmod(0o600)
        with mock.patch.dict(os.environ, {'UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES': '1'}):
            self.config = Config.load(self.path)
        self.runner = ManagedRunner()
        self.reconciler = ManagedReconciler(self.config, self.root, self.runner)

    def test_explicit_mode_requires_router_capability_contract(self):
        self.raw['router_recovery']['enabled'] = False
        self.path.write_text(json.dumps(self.raw))
        with mock.patch.dict(os.environ, {'UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES': '1'}), self.assertRaises(ConfigError):
            Config.load(self.path)

    def test_patch_changes_only_owned_fields_and_preserves_other_interfaces(self):
        interfaces, native, name, _ = self.reconciler.configuration()
        desired = desired_fields(native, self.config, self.reconciler.discover())
        updated = patch_fields(interfaces, name, desired)
        self.assertEqual(updated[1], interfaces[1])
        self.assertEqual(updated[0]['status']['comment'], 'retain')
        self.assertEqual(updated[0]['tunnel']['id'], 1)
        self.assertEqual(updated[0]['addresses'][0]['cidr'], '203.0.113.42/32')
        self.assertEqual(updated[0]['tunnel']['localAddress'], {'source': 'interface', 'id': 'eth9', 'ipVersion': 'v6'})
        self.assertEqual(patch_fields(updated, name, controlled(native)), interfaces)

    def test_managed_plan_uses_udapi_not_tunnel_creation_or_alias(self):
        _, _, actions = self.reconciler.plan()
        self.assertTrue(any(a.reason == 'managed-wan-config-drift' for a in actions))
        self.assertFalse(any(a.reason.startswith('owned-tunnel') for a in actions))
        self.assertFalse(any('alias' in a.command for a in actions))
        self.assertFalse(any(a.reason == 'wan-policy-dispatch-missing' for a in actions))
        self.assertTrue(self.reconciler.router.bind_monitors)
        outer = next(a for a in actions if a.reason == 'outer-rule-missing')
        self.assertEqual(outer.command[3:6], ('-I', 'UBIOS_INPUT_USER_HOOK', '1'))

    def test_update_and_inverse_use_stdin_without_exposing_configuration(self):
        original = copy.deepcopy(self.runner.data['interfaces'])
        _, _, actions = self.reconciler.plan()
        action = next(a for a in actions if a.reason == 'managed-wan-config-drift')
        self.assertNotIn('203.0.113', str(action.share_safe()))
        action.apply_callback()
        self.assertNotEqual(self.runner.data['interfaces'], original)
        self.assertEqual(self.runner.commands[-1][-1], '@/dev/stdin')
        action.undo_callback()
        self.assertEqual(self.runner.data['interfaces'], original)

    def test_concurrent_unrelated_interface_change_blocks_write(self):
        _, _, actions = self.reconciler.plan()
        action = next(a for a in actions if a.reason == 'managed-wan-config-drift')
        self.runner.data['interfaces'][1]['preserve'] = 'changed'
        with self.assertRaises(ForeignConflict):
            action.apply_callback()

    def test_unknown_native_type_and_other_br_fail_closed(self):
        self.runner.data['interfaces'][0]['tunnel']['mode'] = 'gre'
        with self.assertRaises(PrerequisiteUnavailable):
            self.reconciler.configuration()
        self.runner.data['interfaces'][0] = copy.deepcopy(NATIVE)
        self.runner.data['interfaces'][0]['tunnel']['remoteAddress'] = '2001:db8::999'
        with self.assertRaises(ForeignConflict):
            self.reconciler.configuration()

    def test_api_rejection_does_not_mean_success(self):
        _, _, actions = self.reconciler.plan()
        self.runner.input_json = mock.Mock(return_value=mock.Mock(returncode=0, stdout='{"statusCode":400}'))
        action = next(a for a in actions if a.reason == 'managed-wan-config-drift')
        with self.assertRaises(MutationError):
            action.apply_callback()

    def test_recovery_whitelist_does_not_retarget_unifi_policy_dispatch(self):
        record = {'standalone_name': 'jpix0', 'native_name': 'ip6tnl1', 'firewall': [
            ['iptables', 'filter', 'UBIOS_INPUT_USER_HOOK', '-i', 'jpix0'],
            ['iptables', 'nat', 'UBIOS_POSTROUTING_USER_HOOK', '-o', 'jpix0']]}
        allowed = allowed_rules(record)
        self.assertIn(('iptables', 'nat', 'UBIOS_POSTROUTING_USER_HOOK', '-o', 'ip6tnl1'), allowed)
        self.assertNotIn(('iptables', 'filter', 'UBIOS_INPUT_USER_HOOK', '-i', 'ip6tnl1'), allowed)

    def test_recovery_unknown_tagged_rule_causes_no_deletion(self):
        runner = mock.Mock()
        with mock.patch('unifi_jpix.integration.inventory', return_value=[['foreign']]), self.assertRaises(ForeignConflict):
            clear_rules(runner, {'standalone_name': 'jpix0', 'native_name': 'ip6tnl1', 'firewall': []})
        runner.run.assert_not_called()

    def kernel_plan(self, mode='any/ipv6', local='2001:db8::2'):
        interfaces, native, name, _ = self.reconciler.configuration()
        capabilities = self.reconciler.discover()
        self.runner.data['interfaces'] = patch_fields(interfaces, name, desired_fields(native, self.config, capabilities))
        run = self.runner.run
        def kernel(command, *, check=True):
            if tuple(command) == ('ip', '-d', '-6', 'tunnel', 'show', name):
                output = f'{name}: {mode} remote {self.config.br_ipv6} local {local} encaplimit none\n'
                return subprocess.CompletedProcess(command, 0, output, '')
            return run(command, check=check)
        self.runner.run = kernel
        with mock.patch.object(self.reconciler, '_address_exists', return_value=True):
            return self.reconciler.plan()[2]

    def test_supported_api_selector_is_followed_by_kernel_endpoint_repair(self):
        actions = self.kernel_plan()
        repair = next(a for a in actions if a.reason == 'managed-wan-runtime-drift')
        self.assertEqual(repair.command[:8], ('ip', '-6', 'tunnel', 'change', 'ip6tnl1', 'mode', 'ipip6', 'local'))
        self.assertEqual(repair.inverse[:8], ('ip', '-6', 'tunnel', 'change', 'ip6tnl1', 'mode', 'any', 'local'))
        self.assertEqual(repair.inverse[8], '2001:db8::2')
        self.assertNotIn('2001:db8', str(repair.share_safe()))
        self.assertFalse(any(a.reason == 'managed-wan-config-drift' for a in actions))

    def test_converged_kernel_endpoint_is_not_changed(self):
        actions = self.kernel_plan('ip/ipv6', self.reconciler.discover().local_endpoint)
        self.assertFalse(any(a.reason == 'managed-wan-runtime-drift' for a in actions))

    def test_unknown_kernel_mode_is_rejected_without_mutation(self):
        with self.assertRaises(ForeignConflict):
            self.kernel_plan('gre/ipv6')
        self.assertFalse(any('change' in command for command in self.runner.commands))

    def test_confirmed_migration_makes_late_recovery_timer_a_noop(self):
        self.reconciler.state.write(self.reconciler.state.state_dir / 'managed-migration.json', {'status': 'confirmed'})
        runner = mock.Mock()
        self.assertEqual(recover(self.root, runner), {'status': 'no-recovery-needed'})
        runner.run.assert_not_called()

    def test_no_migration_record_is_safe_for_timer(self):
        runner = mock.Mock()
        self.assertEqual(recover(self.root, runner), {'status': 'no-recovery-needed'})
        runner.run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
