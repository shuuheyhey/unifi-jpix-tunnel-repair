"""Synthetic firewall graphs; tests never contact a router."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from unifi_jpix.core import ForeignConflict, MutationError, PrerequisiteUnavailable, Reconciler, Resources
from unifi_jpix.wan_policy import DISPATCH, DNS_CHAIN, GRAPH, rules, validate
from test_core import FakeRunner


def inventory():
    lines = []
    for chain, targets in GRAPH.items():
        lines += [f'-A {chain} -j {target}' for target in targets]
    for chain, direction, target in DISPATCH:
        lines += [f'-A {chain} {direction} ip6tnl1 -m comment --comment 123 -j {target}',
                  f'-A {chain} {direction} br0 -j {target.replace("WAN", "LAN")}',
                  f'-A {target} -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN',
                  f'-A {target} -j {"RETURN" if "OUT" in target else "DROP"}']
    lines += ['-A UBIOS_DNS_PBR_JUMP -i ip6tnl1 -j RETURN',
              '-A UBIOS_DNS_PBR_JUMP -p udp --dport 20201 -j ACCEPT']
    return '\n'.join(lines) + '\n'


class WanPolicyTests(unittest.TestCase):
    def runner(self, text=None, code=0):
        runner = mock.Mock()
        runner.run.return_value = mock.Mock(returncode=code, stdout=inventory() if text is None else text)
        return runner

    def test_expected_four_interface_limited_dispatch_rules(self):
        result = validate(self.runner(), 'ip6tnl1', 'jpix0')
        self.assertEqual(len(result), 4)
        self.assertEqual(result, rules('jpix0'))
        self.assertTrue(all(rule[-1].startswith('UBIOS_WAN_') for _, rule in result[1:]))
        self.assertEqual(result[0][1][-1], 'RETURN')
        self.assertTrue(all(rule[1] == 'jpix0' for _, rule in result))

    def test_owned_rules_are_accepted_without_modifying_policy_contents(self):
        extra = ''.join('-A ' + chain + ' ' + ' '.join(rule) + '\n' for chain, rule in rules('jpix0'))
        validate(self.runner(extra + inventory()), 'ip6tnl1', 'jpix0')

    def test_unknown_graph_foreign_rule_and_earlier_verdict_are_rejected(self):
        for text in [
            inventory().replace('-A INPUT -j UBIOS_INPUT_JUMP', '-A INPUT -j ACCEPT\n-A INPUT -j UBIOS_INPUT_JUMP'),
            inventory().replace('UBIOS_FORWARD_JUMP -j UBIOS_FORWARD_USER_HOOK', 'UBIOS_FORWARD_JUMP -j OTHER'),
            inventory() + '-A UBIOS_FORWARD_IN_USER -i jpix0 -j UBIOS_WAN_IN_USER\n',
            inventory() + '-A UBIOS_FORWARD_IN_USER -j RETURN\n',
            inventory().replace('ip6tnl1', 'ip6tnl2'),
            inventory().replace('-A UBIOS_INPUT_USER_HOOK -i ip6tnl1', '-A UBIOS_INPUT_USER_HOOK -i br1'),
            inventory() + '-A UBIOS_DNS_PBR_JUMP ' + ' '.join(rules('jpix0')[0][1]) + '\n',
            inventory().replace('-A UBIOS_DNS_PBR_JUMP -i ip6tnl1 -j RETURN', ''),
        ]:
            with self.subTest(text=text), self.assertRaises(ForeignConflict):
                validate(self.runner(text), 'ip6tnl1', 'jpix0')

    def test_empty_or_locked_inventory_is_not_absence(self):
        for code, text in [(4, ''), (0, '')]:
            with self.assertRaises(PrerequisiteUnavailable):
                validate(self.runner(text, code), 'ip6tnl1', 'jpix0')

    def test_duplicate_dns_bypass_rollback_keeps_first_position(self):
        chain, rule = rules('jpix0')[0]
        line = '-A ' + chain + ' ' + ' '.join(rule) + '\n'
        validate(self.runner(line * 2 + inventory()), 'ip6tnl1', 'jpix0')
        with tempfile.TemporaryDirectory() as directory:
            reconciler = Reconciler(mock.Mock(), Path(directory), self.runner(line * 2))
            actions = reconciler._firewall_duplicate_actions({('iptables', (), chain): [rule]}, set())
            self.assertEqual(len(actions), 1)
            self.assertEqual(actions[0].inverse[3:6], ('-I', chain, '1'))

    def test_failed_transaction_removes_only_its_new_dispatch(self):
        # Core transaction semantics cover the same exact inverse used live.
        with tempfile.TemporaryDirectory() as directory:
            runner = FakeRunner()
            reconciler = Reconciler(mock.Mock(webhook_url=None), Path(directory), runner)
            actions = [a for chain, rule in rules('jpix0')
                       for a in reconciler._ensure_xtables('iptables', (), chain, rule, 'wan-policy-dispatch-missing', insert_first=chain == DNS_CHAIN)]
            reconciler.plan = mock.Mock(return_value=(None, Resources(10000, 20000), actions))
            reconciler._runtime = mock.Mock(return_value={})
            reconciler._health_check = mock.Mock(side_effect=MutationError('health-failed'))
            with self.assertRaises(MutationError):
                reconciler.reconcile()
            for action in actions:
                self.assertIn(action.command, runner.commands)
                self.assertIn(action.inverse, runner.commands)
                self.assertEqual(action.inverse[0:5], ('iptables', '-w', '5', '-D', action.command[4]))
            self.assertEqual(actions[0].command[3:6], ('-I', DNS_CHAIN, '1'))


if __name__ == '__main__':
    unittest.main()
