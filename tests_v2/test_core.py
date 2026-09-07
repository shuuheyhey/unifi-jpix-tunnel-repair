from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from unifi_jpix.core import (
    Action,
    Capabilities,
    Config,
    ConfigError,
    ForeignConflict,
    MutationError,
    Reconciler,
    Resources,
    RoutedNetwork,
    Runner,
    TUNNEL_ALIAS,
)


BASE_CONFIG = {
    "schema_version": 2,
    "service": "jpix-v6plus-static-ipv4-one",
    "static_ipv4": "203.0.113.42",
    "br_ipv6": "2001:db8:ffff::1",
    "iid": "00cb:0071:2a00:0000",
    "endpoint_network": {"ipv4_cidr": "192.168.20.0/24"},
    "routed_networks": [
        {"interface": "br0", "ipv4_cidr": "192.168.20.0/24"},
        {"interface": "br2", "ipv4_cidr": "192.168.75.0/24"},
    ],
    "tunnel": {"name": "jpix0", "mtu": 1460, "tcp_mss": 1420},
    "firewall": {"outer_ipip_allow": True},
    "repair": {"interval_seconds": 300},
}


class FakeRunner(Runner):
    def __init__(self, *, rules: str = "", fail_mutation: bool = False, ipv4_inventory: str | None = None, nat_chain_rules: str = ""):
        self.rules = rules
        self.fail_mutation = fail_mutation
        self.ipv4_inventory = ipv4_inventory
        self.nat_chain_rules = nat_chain_rules
        self.commands: list[tuple[str, ...]] = []

    def run(self, command, *, check=True):
        recorded = tuple(command)
        self.commands.append(recorded)
        cmd = recorded
        if cmd and cmd[0] in {"iptables", "ip6tables"} and cmd[1:3] == ("-w", "5"):
            cmd = (cmd[0], *cmd[3:])
        elif cmd and cmd[0] in {"iptables-save", "ip6tables-save"} and cmd[1:3] == ("-w", "5"):
            cmd = (cmd[0],)
        stdout = ""
        returncode = 0
        if cmd == ("ubnt-device-info", "model"):
            stdout = "UniFi Dream Machine Pro\n"
        elif cmd == ("ubnt-device-info", "firmware"):
            stdout = "99.99.1\n"
        elif cmd[:5] == ("ip", "-6", "route", "get", "2001:db8:ffff::1"):
            stdout = "2001:db8:ffff::1 via fe80::1 dev eth9 src 2001:db8:1::2 metric 512\n"
        elif cmd == ("ip", "-o", "link", "show", "dev", "eth9"):
            stdout = "2: eth9: <UP,LOWER_UP> mtu 1500 state UP\n"
        elif cmd == ("ip", "-4", "route", "show", "table", "main", "exact", "192.168.20.0/24"):
            stdout = "192.168.20.0/24 dev br0 proto kernel scope link\n"
        elif cmd == ("ip", "-d", "link", "show", "type", "bridge"):
            stdout = "10: br0: <UP> mtu 1500\n11: br2: <UP> mtu 1500\n"
        elif cmd == ("ip", "-6", "route", "show", "table", "all", "proto", "kernel"):
            stdout = "240b:1234:5678:20::/64 dev br0 proto kernel\n240b:1234:5678:21::/64 dev br2 proto kernel\n"
        elif cmd in (("iptables", "--version"), ("ip6tables", "--version")):
            stdout = f"{cmd[0]} v1.8.7 (legacy)\n"
        elif cmd == ("iptables", "-t", "nat", "-S", "UBIOS_POSTROUTING_USER_HOOK"):
            stdout = "-N UBIOS_POSTROUTING_USER_HOOK\n" + self.nat_chain_rules
        elif cmd == ("iptables", "-t", "nat", "-S"):
            stdout = "-A POSTROUTING -j UBIOS_POSTROUTING_USER_HOOK\n"
        elif cmd == ("ip6tables", "-S", "UBIOS_INPUT_USER_HOOK"):
            stdout = "-N UBIOS_INPUT_USER_HOOK\n"
        elif cmd == ("ip6tables", "-S"):
            stdout = "-A INPUT -j UBIOS_INPUT_USER_HOOK\n"
        elif cmd == ("iptables-save",):
            stdout = self.ipv4_inventory or "*filter\n:FORWARD ACCEPT [0:0]\nCOMMIT\n"
        elif cmd == ("ip6tables-save",):
            stdout = "*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n"
        elif cmd[:6] == ("ip", "-d", "-6", "tunnel", "show", "jpix0"):
            returncode = 1
        elif cmd == ("cat", "/sys/class/net/jpix0/ifalias"):
            stdout = TUNNEL_ALIAS + "\n"
        elif cmd[:6] == ("ip", "-o", "link", "show", "dev", "jpix0"):
            returncode = 1
        elif cmd == ("ip", "-4", "rule", "show"):
            stdout = self.rules
        elif cmd == ("ip", "-4", "route", "show", "table", "10000", "default"):
            stdout = "default dev jpix0\n"
        elif cmd[:6] == ("ip", "-4", "route", "show", "table"):
            stdout = ""
        elif cmd[0] in {"iptables", "ip6tables"} and "-C" in cmd:
            if not (cmd[0] == "iptables" and "-t" in cmd and "nat" in cmd and self.nat_chain_rules):
                returncode = 1
        elif cmd[0] == "curl" and "--write-out" in cmd:
            stdout = "200"
            Path(cmd[cmd.index("--output") + 1]).write_text("OK\n", encoding="utf-8")
        elif cmd[:5] in (("ip", "-6", "-o", "address", "show"), ("ip", "-4", "-o", "address", "show")):
            stdout = ""
        elif self.fail_mutation and cmd[0] == "mutate":
            returncode = 1
        result = subprocess.CompletedProcess(command, returncode, stdout, "")
        if check and returncode:
            raise RuntimeError("command failed")
        return result


class WarmingRunner(FakeRunner):
    def __init__(self):
        super().__init__()
        self.ipv4_pings = 0

    def run(self, command, *, check=True):
        if tuple(command[:4]) == ("ping", "-4", "-I", "jpix0"):
            self.ipv4_pings += 1
            if self.ipv4_pings == 1:
                self.commands.append(tuple(command))
                return subprocess.CompletedProcess(command, 1, "", "")
        return super().run(command, check=check)


class LockingSaveRunner(FakeRunner):
    def __init__(self):
        super().__init__()
        self.v4_saves = 0

    def run(self, command, *, check=True):
        if tuple(command) == ("iptables-save",):
            self.v4_saves += 1
            if self.v4_saves == 1:
                self.commands.append(tuple(command))
                return subprocess.CompletedProcess(command, 4, "", "xtables lock")
        return super().run(command, check=check)


class ConfigTests(unittest.TestCase):
    def load(self, value=BASE_CONFIG):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "config.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        path.chmod(0o600)
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES": "1"}):
            return Config.load(path)

    def test_loads_schema_two(self):
        config = self.load()
        self.assertEqual(config.tunnel_name, "jpix0")
        self.assertEqual([item.interface for item in config.routed_networks], ["br0", "br2"])

    def test_rejects_unknown_field(self):
        value = dict(BASE_CONFIG)
        value["unknown"] = True
        with self.assertRaises(ConfigError):
            self.load(value)

    def test_rejects_overlapping_networks(self):
        value = dict(BASE_CONFIG)
        value["routed_networks"] = [
            {"interface": "br0", "ipv4_cidr": "192.168.20.0/24"},
            {"interface": "br2", "ipv4_cidr": "192.168.20.0/25"},
        ]
        with self.assertRaises(ConfigError):
            self.load(value)


class ReconcilerTests(ConfigTests):
    def reconciler(self, runner):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        return Reconciler(self.load(), root, runner)

    def test_unknown_versions_are_capability_metadata_not_a_gate(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            capabilities = reconciler.discover()
        self.assertEqual(capabilities.network_version, "unknown")
        self.assertEqual(capabilities.wan_interface, "eth9")
        self.assertEqual(capabilities.endpoint_interface, "br0")

    def test_plan_creates_project_owned_tunnel_and_scoped_rules(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            _, resources, actions = reconciler.plan()
        commands = [action.command for action in actions]
        self.assertTrue(any(command[:6] == ("ip", "-6", "tunnel", "add", "jpix0", "mode") for command in commands))
        self.assertTrue(any("dev" in command and "eth9" in command for command in commands if "tunnel" in command))
        self.assertTrue(any("192.168.20.0/24" in command and "iif" in command for command in commands))
        self.assertTrue(any(
            command[:7] == ("ip", "-4", "rule", "add", "pref", "20002", "from")
            and command[7:] == ("203.0.113.42/32", "lookup", "10000")
            for command in commands
        ))
        self.assertEqual(resources.route_table, 10000)
        self.assertEqual(resources.rule_priority_base, 20000)

    def test_foreign_rule_at_allocated_priority_is_quarantined_before_mutation(self):
        runner = FakeRunner(rules="20000:\tfrom all iif evil0 lookup 999\n")
        reconciler = self.reconciler(runner)
        reconciler.state.write(
            reconciler.state.runtime_path,
            {"resources": {"route_table": 10000, "rule_priority_base": 20000}},
        )
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            with self.assertRaises(ForeignConflict):
                reconciler.plan()

    def test_foreign_rule_at_router_source_priority_is_quarantined(self):
        runner = FakeRunner(rules="20002:\tfrom all lookup 999\n")
        reconciler = self.reconciler(runner)
        reconciler.state.write(
            reconciler.state.runtime_path,
            {"resources": {"route_table": 10000, "rule_priority_base": 20000}},
        )
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            with self.assertRaises(ForeignConflict):
                reconciler.plan()

    def test_kernel_display_without_host_prefix_matches_router_source_rule(self):
        runner = FakeRunner(rules="20002:\tfrom 203.0.113.42 lookup 10000\n")
        reconciler = self.reconciler(runner)
        reconciler.state.write(
            reconciler.state.runtime_path,
            {"resources": {"route_table": 10000, "rule_priority_base": 20000}},
        )
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            _, _, actions = reconciler.plan()
        self.assertFalse(any(action.reason == "router-source-policy-rule-missing" for action in actions))

    def test_project_tag_outside_owned_firewall_scope_is_rejected(self):
        inventory = (
            "*raw\n:PREROUTING ACCEPT [0:0]\n"
            "-A PREROUTING -m comment --comment unifi-jpix-tunnel-repair:v2 -j ACCEPT\nCOMMIT\n"
        )
        reconciler = self.reconciler(FakeRunner(ipv4_inventory=inventory))
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            with self.assertRaises(ForeignConflict):
                reconciler.plan()

    def test_duplicate_project_firewall_rule_is_reduced_to_one(self):
        rule = (
            "-A UBIOS_POSTROUTING_USER_HOOK -s 192.168.20.0/24 -o jpix0 "
            "-m comment --comment unifi-jpix-tunnel-repair:v2 -j SNAT --to-source 203.0.113.42\n"
        )
        reconciler = self.reconciler(FakeRunner(nat_chain_rules=rule + rule))
        with mock.patch.dict(os.environ, {"UNIFI_JPIX_NETWORK_VERSION_FILE": "/nonexistent"}):
            _, _, actions = reconciler.plan()
        duplicate_actions = [action for action in actions if action.reason == "duplicate-firewall-rule"]
        self.assertEqual(len(duplicate_actions), 1)

    def test_wan_move_removes_endpoint_from_previous_wan(self):
        reconciler = self.reconciler(FakeRunner())
        reconciler.state.write(reconciler.state.runtime_path, {
            "local_endpoint": "240b:1234:5678:20:cb:71:2a00:0",
            "wan_interface": "eth8",
        })
        capabilities = Capabilities(
            "UDM Pro", "verified", "1", "1", "eth9", "240b::2", 1500,
            "br0", "240b:1234:5678:20::/64", "240b:1234:5678:20:cb:71:2a00:0",
            "UBIOS_POSTROUTING_USER_HOOK", "UBIOS_INPUT_USER_HOOK", "iptables-legacy",
        )
        with mock.patch.object(reconciler, "_address_exists", return_value=True):
            actions = reconciler._endpoint_cleanup_actions(capabilities)
        self.assertIn("eth8", actions[0].command)
        self.assertEqual(actions[0].reason, "obsolete-endpoint-address")

    def test_health_failure_rolls_back_applied_actions(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        capabilities = Capabilities(
            "UDM Pro", "verified", "1", "1", "eth9", "240b::2", 1500,
            "br0", "240b:1234:5678:20::/64", "240b:1234:5678:20:cb:71:2a00:0",
            "UBIOS_POSTROUTING_USER_HOOK", "UBIOS_INPUT_USER_HOOK", "iptables-legacy",
        )
        actions = [
            Action("first", ("apply-one",), ("undo-one",)),
            Action("second", ("apply-two",), ("undo-two",)),
        ]
        with mock.patch.object(reconciler, "plan", return_value=(capabilities, Resources(10000, 20000), actions)), \
             mock.patch.object(reconciler, "_health_check", side_effect=MutationError("health-failed")):
            with self.assertRaises(MutationError):
                reconciler.reconcile()
        self.assertLess(runner.commands.index(("undo-two",)), runner.commands.index(("undo-one",)))
        journal = reconciler.state.read(reconciler.state.journal_path)
        self.assertEqual(journal["status"], "health-failed")

    def test_provider_failure_is_deferred_without_data_plane_rollback(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        capabilities = Capabilities(
            "UDM Pro", "verified", "1", "1", "eth9", "240b::2", 1500,
            "br0", "240b:1234:5678:20::/64", "240b:1234:5678:20:cb:71:2a00:0",
            "UBIOS_POSTROUTING_USER_HOOK", "UBIOS_INPUT_USER_HOOK", "iptables-legacy",
        )
        with mock.patch.object(reconciler, "plan", return_value=(capabilities, Resources(10000, 20000), [])), \
             mock.patch.object(reconciler, "_health_check"), \
             mock.patch.object(reconciler, "_notify_provider", side_effect=MutationError("provider")):
            result = reconciler.reconcile()
        self.assertEqual(result["status"], "healthy")
        self.assertEqual(result["provider_update"], "deferred")
        self.assertTrue(reconciler.state.notification_path.is_file())

    def test_deactivate_removes_only_recorded_project_runtime(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        reconciler.state.write(reconciler.state.runtime_path, {
            "schema": 2,
            "resources": {"route_table": 10000, "rule_priority_base": 20000},
            "local_endpoint": "240b:1234:5678:20:cb:71:2a00:0",
            "wan_interface": "eth9",
            "tunnel_name": "jpix0",
            "nat_chain": "UBIOS_POSTROUTING_USER_HOOK",
            "v6_input_chain": "UBIOS_INPUT_USER_HOOK",
        })
        reconciler.deactivate()
        self.assertFalse(reconciler.state.runtime_path.exists())
        self.assertIn(("ip", "-6", "tunnel", "del", "jpix0"), runner.commands)

    def test_deactivate_cleans_all_lan_routes_and_preserves_foreign_routes(self):
        self._check_deactivate_routes(False)

    def test_deactivate_route_failure_retains_ownership_state(self):
        self._check_deactivate_routes(True)

    def _check_deactivate_routes(self, fail_first):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        reconciler.state.write(reconciler.state.runtime_path, {
            "schema": 2,
            "resources": {"route_table": 10000, "rule_priority_base": 20000},
            "local_endpoint": "240b:1234:5678:20:cb:71:2a00:0",
            "wan_interface": "eth9", "tunnel_name": "jpix0",
            "nat_chain": "UBIOS_POSTROUTING_USER_HOOK",
            "v6_input_chain": "UBIOS_INPUT_USER_HOOK",
        })
        owned = {("10000", network.ipv4_cidr, network.interface)
                 for network in reconciler.config.routed_networks}
        foreign = {("main", "192.168.20.0/24", "br0"),
                   ("10000", "192.168.99.0/24", "br9")}
        routes = owned | foreign
        first = ("10000", "192.168.20.0/24", "br0")
        original_run = runner.run

        def run(command, *, check=True):
            if tuple(command[:5]) == ("ip", "-4", "route", "del", "table"):
                key = (command[5], command[6], command[8])
                if fail_first and key == first:
                    return subprocess.CompletedProcess(command, 1, "", "")
                routes.discard(key)
            return original_run(command, check=check)

        with mock.patch.object(runner, "run", side_effect=run):
            if fail_first:
                with self.assertRaises(MutationError):
                    reconciler.deactivate()
            else:
                reconciler.deactivate()
        self.assertEqual(routes, foreign | ({first} if fail_first else set()))
        self.assertEqual(reconciler.state.runtime_path.exists(), fail_first)
        if fail_first:
            self.assertEqual(reconciler.state.read(reconciler.state.quarantine_path)["reason"], "deactivation-failed")

    def test_health_uses_supported_route_table_listing(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)
        capabilities = Capabilities(
            "UDM Pro", "verified", "1", "1", "eth9", "240b::2", 1500,
            "br0", "240b:1234:5678:20::/64", "240b:1234:5678:20:cb:71:2a00:0",
            "UBIOS_POSTROUTING_USER_HOOK", "UBIOS_INPUT_USER_HOOK", "iptables-legacy",
        )
        reconciler._health_check(capabilities, Resources(10000, 20000))
        self.assertIn(("ip", "-4", "route", "show", "table", "10000", "default"), runner.commands)
        self.assertFalse(any(command[:4] == ("ip", "-4", "route", "get") and "table" in command for command in runner.commands))

    def test_health_retries_without_removing_a_warming_tunnel(self):
        runner = WarmingRunner()
        reconciler = self.reconciler(runner)
        capabilities = Capabilities(
            "UDM Pro", "verified", "1", "1", "eth9", "240b::2", 1500,
            "br0", "240b:1234:5678:20::/64", "240b:1234:5678:20:cb:71:2a00:0",
            "UBIOS_POSTROUTING_USER_HOOK", "UBIOS_INPUT_USER_HOOK", "iptables-legacy",
        )
        with mock.patch("unifi_jpix.core.time.sleep") as sleep:
            reconciler._health_check(capabilities, Resources(10000, 20000))
        self.assertEqual(runner.ipv4_pings, 2)
        sleep.assert_called_once_with(2)

    def test_firewall_inventory_retries_a_transient_lock(self):
        runner = LockingSaveRunner()
        reconciler = self.reconciler(runner)
        with mock.patch("unifi_jpix.core.time.sleep") as sleep:
            reconciler.plan()
        self.assertEqual(runner.v4_saves, 2)
        sleep.assert_called_once_with(1)

    def test_xtables_operations_wait_for_the_global_lock(self):
        runner = FakeRunner()
        reconciler = self.reconciler(runner)

        reconciler.plan()

        commands = [
            command for command in runner.commands
            if command[0] in {"iptables", "ip6tables"}
            and command[1:] != ("--version",)
        ]
        self.assertTrue(commands)
        self.assertTrue(all(command[1:3] == ("-w", "5") for command in commands))


class ProviderConfigTests(ConfigTests):
    def test_http_provider_requires_matching_explicit_opt_in(self):
        value = dict(BASE_CONFIG)
        value["provider"] = {"update_url": "http://provider.example/update"}
        with self.assertRaises(ConfigError):
            self.load(value)
        value["provider"] = {
            "update_url": "http://provider.example/update",
            "allow_insecure_http": True,
            "insecure_http_host": "provider.example",
            "credentials_file": "/data/unifi-jpix-tunnel-repair/credentials-v2.json",
        }
        self.assertTrue(self.load(value).provider_allow_insecure_http)

    def test_provider_secret_is_not_placed_in_process_arguments(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        credentials = Path(directory.name) / "credentials.json"
        credentials.write_text(json.dumps({
            "provider_username": "secret-user",
            "provider_password": "secret-password",
        }), encoding="utf-8")
        credentials.chmod(0o600)
        value = dict(BASE_CONFIG)
        value["provider"] = {
            "update_url": "https://provider.example/update",
            "credentials_file": str(credentials),
        }
        runner = FakeRunner()
        reconciler = Reconciler(self.load(value), Path(directory.name), runner)
        self.assertEqual(reconciler._notify_provider("240b:1234:5678:20:cb:71:2a00:0"), "success")
        arguments = "\n".join(" ".join(command) for command in runner.commands)
        self.assertNotIn("secret-user", arguments)
        self.assertNotIn("secret-password", arguments)
        self.assertFalse(list((Path(directory.name) / "state-v2").glob(".provider-update.*")))


if __name__ == "__main__":
    unittest.main()
