"""Synthetic single-WAN adapter fixtures; no device data or credentials."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from unifi_jpix.core import Action, Config, ConfigError, ForeignConflict, MutationError, Reconciler, Resources, StateStore, _xtables_equivalent
from unifi_jpix.router import RouterRecovery, binding_patch, topology
from test_core import BASE_CONFIG, FakeRunner


FLAGS = ('bindAddress', 'bindDomainResolution', 'bindInterface', 'bindRoutingTable')
SERVICES = {
    'dnsForwarder': {'enabled': True},
    'wifiman': {'token': 'synthetic-secret'},
    'wanFailover': {
        'enabled': True,
        'failoverGroups': [{'algorithm': 'single', 'interfaces': ['ip6tnl1']}],
        'wanInterfaces': [{'interface': 'ip6tnl1', 'routingTable': 201,
                           'monitors': [{'id': 1, **dict.fromkeys(FLAGS, True)}]}],
    },
}
RULES = ('0: from all lookup local\n32000: from all lookup main\n'
         '32501: from all fwmark 0x1a0000/0x7e0000 lookup 201.ip6tnl1\n'
         '32766: from all lookup 201.ip6tnl1\n')


class RouterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'config.json'
        self.raw = copy.deepcopy(BASE_CONFIG)
        self.raw['router_recovery'] = {'enabled': True}
        self.path.write_text(json.dumps(self.raw))
        self.path.chmod(0o600)
        with mock.patch.dict(os.environ, {'UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES': '1'}):
            self.config = Config.load(self.path)

    def adapter(self, rules=RULES):
        runner = FakeRunner(rules=rules)
        adapter = RouterRecovery(self.config, runner, Resources(10000, 20000))
        adapter.services = mock.Mock(return_value=copy.deepcopy(SERVICES))
        return adapter

    def test_explicit_boolean_opt_in(self):
        self.raw['router_recovery']['enabled'] = 'yes'
        self.path.write_text(json.dumps(self.raw))
        with mock.patch.dict(os.environ, {'UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES': '1'}):
            with self.assertRaises(ConfigError):
                Config.load(self.path)

    def test_rules_preserve_main_and_limit_dns_to_local_origin(self):
        adapter = self.adapter()
        actions = adapter.plan()
        commands = [a.command for a in actions]
        self.assertIn(('ip', '-4', 'rule', 'add', 'pref', '32001', 'iif', 'lo', 'lookup', '10000'), commands)
        self.assertIn(('ip', '-4', 'rule', 'add', 'pref', '19999', 'iif', 'lo', 'fwmark', '0x1a0000/0x7e0000', 'lookup', '10000'), commands)
        self.assertNotIn('synthetic-secret', json.dumps([a.share_safe() for a in actions]))

    def test_existing_exact_rules_are_not_duplicated(self):
        rules = RULES + ('32001: from all iif lo lookup 10000\n'
                         '19999: from all fwmark 0x1a0000/0x7e0000 iif lo lookup 10000\n')
        actions = self.adapter(rules).plan()
        self.assertFalse(any(a.command[0] == 'ip' for a in actions))

    def test_conflict_and_duplicate_priorities_fail_closed(self):
        for extra in ['32001: from all lookup 444\n',
                      '32001: from all iif lo lookup 10000\n' * 2,
                      '19999: from all iif lo lookup 444\n']:
            with self.subTest(extra=extra), self.assertRaises(ForeignConflict):
                self.adapter(RULES + extra).plan()

    def test_unknown_main_priority_is_rejected(self):
        with self.assertRaises(ForeignConflict):
            self.adapter(RULES.replace('32000:', '32005:')).plan()

    def test_multiwan_and_unknown_binding_types_rejected(self):
        data = copy.deepcopy(SERVICES)
        data['wanFailover']['wanInterfaces'] *= 2
        with self.assertRaises(ForeignConflict):
            topology(data)
        data = copy.deepcopy(SERVICES)
        data['wanFailover']['wanInterfaces'][0]['monitors'][0]['bindAddress'] = 1
        with self.assertRaises(ForeignConflict):
            topology(data)

    def test_patch_preserves_every_non_binding_value(self):
        updated = binding_patch(SERVICES, False)
        self.assertEqual(updated['wifiman'], SERVICES['wifiman'])
        self.assertEqual(updated['dnsForwarder'], SERVICES['dnsForwarder'])
        monitor = updated['wanFailover']['wanInterfaces'][0]['monitors'][0]
        self.assertTrue(all(monitor[f] is False for f in FLAGS))
        self.assertEqual(binding_patch(updated, True), SERVICES)

    def test_reprovision_plans_monitor_repair_and_already_repaired_is_noop(self):
        adapter = self.adapter()
        self.assertTrue(any(a.reason == 'wan-monitor-binding-drift' for a in adapter.plan()))
        adapter.services.return_value = binding_patch(SERVICES, False)
        self.assertFalse(any(a.reason == 'wan-monitor-binding-drift' for a in adapter.plan()))

    def test_monitor_update_uses_stdin_and_rollback_restores_exact_configuration(self):
        adapter = self.adapter()
        live = copy.deepcopy(SERVICES)
        adapter.services.side_effect = lambda: copy.deepcopy(live)
        def put(command, payload):
            self.assertNotIn('synthetic-secret', repr(command))
            live.clear()
            live.update(copy.deepcopy(payload))
            return mock.Mock(returncode=0, stdout='{}')
        adapter.runner.input_json = mock.Mock(side_effect=put)
        action = next(a for a in adapter.plan() if a.reason == 'wan-monitor-binding-drift')
        action.apply_callback()
        self.assertEqual(live, binding_patch(SERVICES, False))
        action.undo_callback()
        self.assertEqual(live, SERVICES)

    def test_concurrent_change_prevents_monitor_write(self):
        adapter = self.adapter()
        action = next(a for a in adapter.plan() if a.reason == 'wan-monitor-binding-drift')
        changed = copy.deepcopy(SERVICES)
        changed['dnsForwarder']['enabled'] = False
        adapter.services.return_value = changed
        adapter.runner.input_json = mock.Mock()
        with self.assertRaises(ForeignConflict):
            action.apply_callback()
        adapter.runner.input_json.assert_not_called()

    def test_api_error_with_zero_exit_is_not_success(self):
        adapter = self.adapter()
        adapter.runner.input_json = mock.Mock(return_value=mock.Mock(returncode=0, stdout='{"statusCode": 400}'))
        action = next(a for a in adapter.plan() if a.reason == 'wan-monitor-binding-drift')
        with self.assertRaises(MutationError):
            action.apply_callback()

    def test_persistent_enrollment_is_private_and_contains_no_service_secrets(self):
        adapter = self.adapter()
        adapter.state = StateStore(Path(self.temp.name))
        actions = adapter.plan()
        action = next(a for a in actions if a.reason == 'router-recovery-enroll')
        action.apply_callback()
        path = adapter.state.state_dir / 'router-recovery.json'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('synthetic-secret', path.read_text())
        self.assertFalse(any(a.reason == 'router-recovery-enroll' for a in adapter.plan()))
        action.undo_callback()
        self.assertFalse(path.exists())

    def test_udapi_monitor_callback_is_reversed_when_core_health_fails(self):
        adapter = self.adapter()
        live = copy.deepcopy(SERVICES)
        adapter.services.side_effect = lambda: copy.deepcopy(live)
        def put(_command, payload):
            live.clear()
            live.update(copy.deepcopy(payload))
            return mock.Mock(returncode=0, stdout='{}')
        adapter.runner.input_json = mock.Mock(side_effect=put)
        actions = [a for a in adapter.plan() if a.reason == 'wan-monitor-binding-drift']
        reconciler = Reconciler(self.config, Path(self.temp.name), adapter.runner)
        reconciler.plan = mock.Mock(side_effect=[(None, Resources(10000, 20000), actions),
                                                 (None, Resources(10000, 20000), [])])
        reconciler._runtime = mock.Mock(return_value={})
        reconciler._health_check = mock.Mock(side_effect=MutationError('health-failed'))
        with mock.patch('unifi_jpix.core.time.sleep'), self.assertRaises(MutationError):
            reconciler.reconcile()
        self.assertEqual(live, SERVICES)

    def test_udp_module_normalization_matches_kernel_output(self):
        adapter = self.adapter()
        adapter.plan()
        expected = adapter.dns_snat_rule()
        actual = list(expected)
        index = actual.index('--dport')
        actual[index:index] = ['-m', 'udp']
        self.assertTrue(_xtables_equivalent(actual, expected))

    def test_async_firewall_rebuild_is_repaired_before_health_is_recorded(self):
        adapter = self.adapter()
        reconciler = Reconciler(self.config, Path(self.temp.name), adapter.runner)
        monitor = Action('wan-monitor-binding-drift', ('udapi-monitor',), apply_callback=lambda: None)
        snat = Action('router-dns-snat-missing', ('mutate', 'restore-snat'), ('undo', 'restore-snat'))
        capabilities = reconciler.discover()
        reconciler.plan = mock.Mock(side_effect=[(capabilities, Resources(10000, 20000), [monitor]),
                                                 (capabilities, Resources(10000, 20000), [snat])])
        reconciler._runtime = mock.Mock(return_value={})
        def health(*_args):
            self.assertIn(('mutate', 'restore-snat'), adapter.runner.commands)
        reconciler._health_check = mock.Mock(side_effect=health)
        with mock.patch('unifi_jpix.core.time.sleep') as sleep:
            result = reconciler.reconcile()
        sleep.assert_called_once_with(10)
        self.assertEqual(result['repairs'], 2)
        journal = reconciler.state.read(reconciler.state.journal_path)
        self.assertEqual(journal['actions'], ['wan-monitor-binding-drift', 'router-dns-snat-missing'])
        self.assertEqual(journal['status'], 'verified')


if __name__ == '__main__':
    unittest.main()
