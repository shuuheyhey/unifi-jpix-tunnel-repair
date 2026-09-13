"""Capability discovery and desired-state reconciliation for JPIX fixed IP."""

from __future__ import annotations

from dataclasses import dataclass, field
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import tempfile
import time
from typing import Any, Callable, Sequence
from urllib.parse import urlparse


PROJECT = "unifi-jpix-tunnel-repair"
TUNNEL_ALIAS = f"{PROJECT}:v2"
FIREWALL_TAG = f"{PROJECT}:v2"
SUPPORTED_MODELS = {
    "UniFi Dream Machine Pro": "verified",
    "UDM Pro": "verified",
    "UniFi Dream Machine SE": "preview",
    "UDM SE": "preview",
    "UniFi Dream Machine Pro Max": "preview",
    "UDM Pro Max": "preview",
}
DEFAULT_ROOT = Path("/data/unifi-jpix-tunnel-repair")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")


class JpixError(RuntimeError):
    """Expected, share-safe operational failure."""


class ConfigError(JpixError):
    pass


class PrerequisiteUnavailable(JpixError):
    pass


class ForeignConflict(JpixError):
    pass


class MutationError(JpixError):
    pass


@dataclass(frozen=True)
class RoutedNetwork:
    interface: str
    ipv4_cidr: str


@dataclass(frozen=True)
class Config:
    schema_version: int
    service: str
    static_ipv4: str
    br_ipv6: str
    iid: str
    endpoint_interface: str | None
    endpoint_ipv4_cidr: str | None
    routed_networks: tuple[RoutedNetwork, ...]
    tunnel_name: str
    tunnel_mtu: int
    tcp_mss: int
    route_table: int | None
    rule_priority_base: int | None
    outer_ipip_allow: bool
    provider_url: str | None
    provider_allow_insecure_http: bool
    provider_insecure_http_host: str | None
    credentials_file: Path | None
    webhook_url: str | None
    reconcile_interval_seconds: int
    router_recovery_enabled: bool = False
    wan_integration: str = 'standalone'

    @classmethod
    def load(cls, path: Path) -> "Config":
        _require_private_file(path, "configuration")
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigError("configuration is not valid JSON") from exc
        if not isinstance(raw, dict):
            raise ConfigError("configuration must be an object")
        allowed = {
            "schema_version", "service", "static_ipv4", "br_ipv6", "iid",
            "endpoint_network", "routed_networks", "tunnel", "resources",
            "firewall", "provider", "webhook", "repair", "router_recovery", "integration",
        }
        _reject_unknown(raw, allowed, "configuration")
        if raw.get("schema_version") != 2:
            raise ConfigError("schema_version must be 2")
        if raw.get("service") != "jpix-v6plus-static-ipv4-one":
            raise ConfigError("unsupported service")
        static_v4 = _ipv4_address(raw.get("static_ipv4"), "static_ipv4")
        documentation_allowed = os.environ.get("UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES") == "1"
        if not documentation_allowed and (static_v4.is_private or static_v4.is_loopback or static_v4.is_multicast):
            raise ConfigError("static_ipv4 must be a public unicast address")
        br_v6 = _ipv6_address(raw.get("br_ipv6"), "br_ipv6")
        if not documentation_allowed and not br_v6.is_global:
            raise ConfigError("br_ipv6 must be a global address")
        iid = _iid(raw.get("iid"))

        endpoint = raw.get("endpoint_network")
        if not isinstance(endpoint, dict):
            raise ConfigError("endpoint_network must be an object")
        _reject_unknown(endpoint, {"interface", "ipv4_cidr"}, "endpoint_network")
        endpoint_interface = endpoint.get("interface")
        endpoint_cidr = endpoint.get("ipv4_cidr")
        if bool(endpoint_interface) == bool(endpoint_cidr):
            raise ConfigError("endpoint_network requires exactly one selector")
        if endpoint_interface is not None:
            endpoint_interface = _interface(endpoint_interface, "endpoint interface")
        if endpoint_cidr is not None:
            endpoint_cidr = str(_private_ipv4_network(endpoint_cidr, "endpoint ipv4_cidr"))

        network_rows = raw.get("routed_networks")
        if not isinstance(network_rows, list) or not network_rows:
            raise ConfigError("routed_networks must be a non-empty array")
        networks: list[RoutedNetwork] = []
        seen_ifaces: set[str] = set()
        seen_cidrs: set[str] = set()
        parsed_networks: list[ipaddress.IPv4Network] = []
        for index, row in enumerate(network_rows):
            if not isinstance(row, dict):
                raise ConfigError(f"routed_networks[{index}] must be an object")
            _reject_unknown(row, {"interface", "ipv4_cidr"}, f"routed_networks[{index}]")
            interface = _interface(row.get("interface"), f"routed_networks[{index}].interface")
            network = _private_ipv4_network(row.get("ipv4_cidr"), f"routed_networks[{index}].ipv4_cidr")
            if interface in seen_ifaces or str(network) in seen_cidrs:
                raise ConfigError("routed_networks selectors must be unique")
            if any(network.overlaps(existing) for existing in parsed_networks):
                raise ConfigError("routed_networks must not overlap")
            seen_ifaces.add(interface)
            seen_cidrs.add(str(network))
            parsed_networks.append(network)
            networks.append(RoutedNetwork(interface, str(network)))

        tunnel = _object(raw.get("tunnel", {}), "tunnel")
        _reject_unknown(tunnel, {"name", "mtu", "tcp_mss"}, "tunnel")
        tunnel_name = _interface(tunnel.get("name", "jpix0"), "tunnel.name")
        if tunnel_name in seen_ifaces:
            raise ConfigError("tunnel.name conflicts with a routed interface")
        mtu = _integer(tunnel.get("mtu", 1460), "tunnel.mtu", 1280, 1460)
        mss = _integer(tunnel.get("tcp_mss", min(1420, mtu - 40)), "tunnel.tcp_mss", 536, mtu - 40)

        resources = _object(raw.get("resources", {}), "resources")
        _reject_unknown(resources, {"route_table", "rule_priority_base"}, "resources")
        route_table = _optional_integer(resources.get("route_table"), "resources.route_table", 1, 4294967295)
        priority = _optional_integer(resources.get("rule_priority_base"), "resources.rule_priority_base", 1, 32700)
        if priority is not None and priority + len(networks) > 32765:
            raise ConfigError("rule priority range exceeds 32765")

        firewall = _object(raw.get("firewall", {}), "firewall")
        _reject_unknown(firewall, {"outer_ipip_allow"}, "firewall")
        outer = firewall.get("outer_ipip_allow", True)
        if not isinstance(outer, bool):
            raise ConfigError("firewall.outer_ipip_allow must be boolean")

        provider = _object(raw.get("provider", {}), "provider")
        _reject_unknown(provider, {"update_url", "allow_insecure_http", "insecure_http_host", "credentials_file"}, "provider")
        provider_url = provider.get("update_url")
        if provider_url is not None and not isinstance(provider_url, str):
            raise ConfigError("provider.update_url must be a string")
        credentials_file = provider.get("credentials_file")
        if credentials_file is not None:
            credentials_file = Path(str(credentials_file))
            if not credentials_file.is_absolute():
                raise ConfigError("provider.credentials_file must be absolute")
        allow_insecure = provider.get("allow_insecure_http", False)
        if not isinstance(allow_insecure, bool):
            raise ConfigError("provider.allow_insecure_http must be boolean")
        insecure_host = provider.get("insecure_http_host")
        if insecure_host is not None and (not isinstance(insecure_host, str) or not insecure_host):
            raise ConfigError("provider.insecure_http_host must be a hostname")
        if provider_url:
            parsed_provider = urlparse(provider_url)
            if not parsed_provider.hostname or parsed_provider.username or parsed_provider.password or parsed_provider.query or parsed_provider.fragment:
                raise ConfigError("provider.update_url is invalid")
            if parsed_provider.scheme == "http":
                if not allow_insecure or insecure_host != parsed_provider.hostname:
                    raise ConfigError("HTTP provider requires explicit matching host opt-in")
            elif parsed_provider.scheme != "https":
                raise ConfigError("provider.update_url scheme is unsupported")
        elif allow_insecure or insecure_host:
            raise ConfigError("provider HTTP opt-in requires update_url")

        webhook = _object(raw.get("webhook", {}), "webhook")
        _reject_unknown(webhook, {"url"}, "webhook")
        webhook_url = webhook.get("url")
        if webhook_url is not None and not isinstance(webhook_url, str):
            raise ConfigError("webhook.url must be a string")
        if webhook_url is not None:
            parsed_webhook = urlparse(webhook_url)
            if parsed_webhook.scheme != "https" or not parsed_webhook.hostname or parsed_webhook.username or parsed_webhook.password:
                raise ConfigError("webhook.url must be an HTTPS URL without credentials")

        repair = _object(raw.get("repair", {}), "repair")
        _reject_unknown(repair, {"interval_seconds"}, "repair")
        interval = _integer(repair.get("interval_seconds", 300), "repair.interval_seconds", 60, 3600)
        if interval != 300:
            raise ConfigError("repair.interval_seconds must be 300 in schema version 2")
        router = _object(raw.get("router_recovery", {}), "router_recovery")
        _reject_unknown(router, {"enabled"}, "router_recovery")
        router_enabled = router.get("enabled", False)
        if not isinstance(router_enabled, bool):
            raise ConfigError("router_recovery.enabled must be boolean")
        integration = _object(raw.get('integration', {}), 'integration')
        _reject_unknown(integration, {'mode'}, 'integration')
        mode = integration.get('mode', 'standalone')
        if mode not in {'standalone', 'unifi-managed'} or (mode == 'unifi-managed' and not router_enabled):
            raise ConfigError('integration.mode is unsupported')
        return cls(
            2, raw["service"], str(static_v4), str(br_v6), iid,
            endpoint_interface, endpoint_cidr, tuple(networks), tunnel_name,
            mtu, mss, route_table, priority, outer, provider_url,
            allow_insecure, insecure_host,
            credentials_file, webhook_url, interval, router_enabled, mode,
        )


@dataclass(frozen=True)
class Capabilities:
    model: str
    model_status: str
    firmware: str
    network_version: str
    wan_interface: str
    wan_source_v6: str
    wan_mtu: int
    endpoint_interface: str
    endpoint_prefix: str
    local_endpoint: str
    nat_chain: str
    v6_input_chain: str
    firewall_backend: str

    def share_safe(self) -> dict[str, Any]:
        return {
            "model": self.model,
            "model_status": self.model_status,
            "firmware": self.firmware,
            "network_version": self.network_version,
            "wan": "ready",
            "endpoint_prefix": "unique",
            "firewall_backend": self.firewall_backend,
            "nat_chain": self.nat_chain,
            "v6_input_chain": self.v6_input_chain,
        }


@dataclass(frozen=True)
class Resources:
    route_table: int
    rule_priority_base: int


@dataclass(frozen=True)
class Action:
    reason: str
    command: tuple[str, ...]
    inverse: tuple[str, ...] | None = None
    apply_callback: Callable[[], None] | None = field(default=None, repr=False, compare=False)
    undo_callback: Callable[[], None] | None = field(default=None, repr=False, compare=False)

    def share_safe(self) -> dict[str, str]:
        return {"reason": self.reason, "operation": self.command[0]}


class Runner:
    def input_json(self, command: Sequence[str], payload: dict[str, Any]) -> subprocess.CompletedProcess[str]:
        # UDAPI services can contain secrets. Never put their JSON in argv or logs.
        return subprocess.run(command, input=json.dumps(payload), text=True, capture_output=True, check=False)

    def run(self, command: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if check and result.returncode != 0:
            raise JpixError(f"command failed: {Path(command[0]).name}")
        return result


class StateStore:
    def __init__(self, root: Path):
        self.root = root
        self.state_dir = root / "state-v2"
        self.runtime_path = self.state_dir / "runtime.json"
        self.previous_path = self.state_dir / "previous-runtime.json"
        self.health_path = self.state_dir / "health.json"
        self.quarantine_path = self.state_dir / "quarantine.json"
        self.notification_path = self.state_dir / "pending-provider.json"
        self.journal_path = self.state_dir / "transaction.json"
        self.lock_path = self.state_dir / "operation.lock"

    def ensure(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.state_dir.chmod(0o700)

    def read(self, path: Path) -> dict[str, Any] | None:
        if not path.exists():
            return None
        _require_private_file(path, "state")
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ForeignConflict("state is invalid") from exc
        if not isinstance(raw, dict):
            raise ForeignConflict("state is invalid")
        return raw

    def write(self, path: Path, value: dict[str, Any]) -> None:
        self.ensure()
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=self.state_dir)
        temp_path = Path(temporary)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(value, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            temp_path.chmod(0o600)
            os.replace(temp_path, path)
        finally:
            temp_path.unlink(missing_ok=True)

    def lock(self):
        self.ensure()
        descriptor = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return os.fdopen(descriptor, "r+")

    def quarantine(self, reason: str) -> None:
        self.write(self.quarantine_path, {"schema": 1, "reason": reason, "at": int(time.time())})

    def clear_quarantine(self) -> None:
        self.quarantine_path.unlink(missing_ok=True)

    def begin_transaction(self, actions: Sequence[Action]) -> None:
        self.write(self.journal_path, {
            "schema": 1,
            "status": "applying",
            "at": int(time.time()),
            "actions": [action.reason for action in actions],
            "completed": 0,
        })

    def transaction_progress(self, completed: int) -> None:
        journal = self.read(self.journal_path) or {}
        journal["completed"] = completed
        self.write(self.journal_path, journal)

    def finish_transaction(self, status: str) -> None:
        journal = self.read(self.journal_path) or {"schema": 1, "at": int(time.time())}
        journal["status"] = status
        journal["finished_at"] = int(time.time())
        self.write(self.journal_path, journal)


class Probe:
    def __init__(self, runner: Runner):
        self.runner = runner

    def text(self, command: Sequence[str], *, allow_failure: bool = False) -> str:
        result = self.runner.run(command, check=not allow_failure)
        return result.stdout.strip()

    def discover(self, config: Config) -> Capabilities:
        model = self.text(["ubnt-device-info", "model"])
        if model not in SUPPORTED_MODELS:
            raise PrerequisiteUnavailable("device model is unsupported")
        firmware = self.text(["ubnt-device-info", "firmware"])
        network_version_path = Path(os.environ.get("UNIFI_JPIX_NETWORK_VERSION_FILE", "/usr/lib/unifi/webapps/ROOT/app-unifi/.version"))
        network_version = network_version_path.read_text(encoding="utf-8").strip() if network_version_path.is_file() else "unknown"

        route = self.text(["ip", "-6", "route", "get", config.br_ipv6])
        wan = _token_after(route, "dev")
        source = _token_after(route, "src")
        _interface(wan, "discovered WAN")
        _ipv6_address(source.split("%", 1)[0], "discovered WAN source")
        link = self.text(["ip", "-o", "link", "show", "dev", wan])
        if "UP" not in link:
            raise PrerequisiteUnavailable("WAN link is not ready")
        mtu = int(_token_after(link, "mtu"))
        if config.tunnel_mtu + 40 > mtu:
            raise PrerequisiteUnavailable("tunnel MTU exceeds underlay capability")

        endpoint_interface = self._endpoint_interface(config)
        prefix = self._endpoint_prefix(endpoint_interface)
        local_endpoint = str(ipaddress.IPv6Address(int(ipaddress.IPv6Network(prefix).network_address) | int(ipaddress.IPv6Address(f"::{config.iid}"))))

        iptables_version = self.text(["iptables", "--version"])
        ip6tables_version = self.text(["ip6tables", "--version"])
        if "legacy" not in iptables_version or "legacy" not in ip6tables_version:
            raise PrerequisiteUnavailable("firewall backend has no implemented adapter")
        nat_chain = self._unique_chain("iptables", ["-t", "nat", "-S"], "UBIOS_POSTROUTING_USER_HOOK")
        v6_chain = self._unique_chain("ip6tables", ["-S"], "UBIOS_INPUT_USER_HOOK")
        return Capabilities(
            model, SUPPORTED_MODELS[model], firmware, network_version, wan,
            source, mtu, endpoint_interface, prefix, local_endpoint,
            nat_chain, v6_chain, "iptables-legacy",
        )

    def _endpoint_interface(self, config: Config) -> str:
        if config.endpoint_interface:
            return config.endpoint_interface
        assert config.endpoint_ipv4_cidr
        routes = self.text(["ip", "-4", "route", "show", "table", "main", "exact", config.endpoint_ipv4_cidr])
        candidates = {
            _token_after(line, "dev") for line in routes.splitlines()
            if line.split() and line.split()[0] == config.endpoint_ipv4_cidr and " dev " in f" {line} "
        }
        if len(candidates) != 1:
            raise PrerequisiteUnavailable("endpoint network selector is not unique")
        return _interface(candidates.pop(), "endpoint interface")

    def _endpoint_prefix(self, interface: str) -> str:
        bridges = self.text(["ip", "-d", "link", "show", "type", "bridge"])
        bridge_names = set(re.findall(r"^\d+: ([^:@]+)", bridges, re.MULTILINE))
        if interface not in bridge_names:
            raise PrerequisiteUnavailable("endpoint interface is not a bridge")
        routes = self.text(["ip", "-6", "route", "show", "table", "all", "proto", "kernel"])
        candidates: set[str] = set()
        for line in routes.splitlines():
            fields = line.split()
            if "dev" not in fields or _token_after(line, "dev") != interface:
                continue
            for field in fields:
                try:
                    network = ipaddress.ip_network(field, strict=False)
                except ValueError:
                    continue
                if isinstance(network, ipaddress.IPv6Network) and network.prefixlen == 64 and network.network_address.is_global:
                    candidates.add(str(network))
        if len(candidates) != 1:
            raise PrerequisiteUnavailable("endpoint delegated prefix is not unique")
        return candidates.pop()

    def _unique_chain(self, binary: str, args: list[str], wanted: str) -> str:
        result = self.runner.run(_xtables_command(binary, *args, wanted), check=False)
        if result.returncode != 0:
            raise PrerequisiteUnavailable("required UniFi user chain is absent")
        full = self.text(_xtables_command(binary, *args))
        jumps = [line for line in full.splitlines() if re.search(rf"(?:-j|--jump) {re.escape(wanted)}(?: |$)", line)]
        if len(jumps) != 1:
            raise PrerequisiteUnavailable("required UniFi user chain parent is not unique")
        return wanted


class Reconciler:
    def __init__(self, config: Config, root: Path, runner: Runner | None = None):
        self.config = config
        self.root = root
        self.runner = runner or Runner()
        self.probe = Probe(self.runner)
        self.state = StateStore(root)
        self.router = None

    def discover(self) -> Capabilities:
        return self.probe.discover(self.config)

    def allocate_resources(self) -> Resources:
        runtime = self.state.read(self.state.runtime_path)
        if runtime and isinstance(runtime.get("resources"), dict):
            data = runtime["resources"]
            if set(data) != {"route_table", "rule_priority_base"}:
                raise ForeignConflict("runtime resource allocation is invalid")
            table = data.get("route_table")
            priority = data.get("rule_priority_base")
            if not isinstance(table, int) or isinstance(table, bool) or not isinstance(priority, int) or isinstance(priority, bool):
                raise ForeignConflict("runtime resource allocation is invalid")
            if self.config.route_table is not None and table != self.config.route_table:
                raise ForeignConflict("runtime route table conflicts with configuration")
            if self.config.route_table is None and not 10000 <= table < 11000:
                raise ForeignConflict("runtime route table is outside the allocation pool")
            if self.config.rule_priority_base is not None and priority != self.config.rule_priority_base:
                raise ForeignConflict("runtime policy priority conflicts with configuration")
            if self.config.rule_priority_base is None and not 20000 <= priority < 21000:
                raise ForeignConflict("runtime policy priority is outside the allocation pool")
            if priority + len(self.config.routed_networks) > 32765:
                raise ForeignConflict("runtime policy priority range is invalid")
            return Resources(table, priority)
        count = len(self.config.routed_networks) + 1
        table = self.config.route_table or self._find_table()
        priority = self.config.rule_priority_base or self._find_priorities(count)
        return Resources(table, priority)

    def _find_table(self) -> int:
        inventory = self.runner.run(["ip", "-4", "route", "show", "table", "all"], check=False)
        if inventory.returncode != 0:
            raise PrerequisiteUnavailable("route table inventory is unavailable")
        used = {int(match.group(1)) for match in re.finditer(r"\btable (\d+)\b", inventory.stdout)}
        for candidate in range(10000, 11000):
            if candidate not in used:
                return candidate
        raise ForeignConflict("no free route table in the project allocation pool")

    def _find_priorities(self, count: int) -> int:
        output = self.runner.run(["ip", "-4", "rule", "show"]).stdout
        used = {int(match.group(1)) for match in re.finditer(r"(?m)^(\d+):", output)}
        for base in range(20000, 21000 - count + 1):
            if all(base + offset not in used for offset in range(count)):
                return base
        raise ForeignConflict("no free policy-rule range in the project allocation pool")

    def plan(self) -> tuple[Capabilities, Resources, list[Action]]:
        capabilities = self.discover()
        resources = self.allocate_resources()
        actions: list[Action] = []
        cfg = self.config
        self.router = None
        if cfg.router_recovery_enabled:
            from .router import RouterRecovery
            self.router = RouterRecovery(cfg, self.runner, resources, self.state)
            router_actions = self.router.plan()
        else:
            if (self.state.state_dir / "router-recovery.json").exists():
                raise ForeignConflict("disable router recovery only after deactivation")
            router_actions = []
        local = capabilities.local_endpoint

        if not self._address_exists(capabilities.wan_interface, f"{local}/128", 6):
            actions.append(Action("endpoint-address-missing", ("ip", "-6", "address", "add", f"{local}/128", "dev", capabilities.wan_interface), ("ip", "-6", "address", "del", f"{local}/128", "dev", capabilities.wan_interface)))

        tunnel = self.runner.run(["ip", "-d", "-6", "tunnel", "show", cfg.tunnel_name], check=False)
        tunnel_created = tunnel.returncode != 0 or not tunnel.stdout.strip()
        if tunnel_created:
            actions.append(Action("owned-tunnel-missing", ("ip", "-6", "tunnel", "add", cfg.tunnel_name, "mode", "ipip6", "local", local, "remote", cfg.br_ipv6, "dev", capabilities.wan_interface, "encaplimit", "none"), ("ip", "-6", "tunnel", "del", cfg.tunnel_name)))
            actions.append(Action("owned-tunnel-alias", ("ip", "link", "set", "dev", cfg.tunnel_name, "alias", TUNNEL_ALIAS), None))
        else:
            alias = self.runner.run(["cat", f"/sys/class/net/{cfg.tunnel_name}/ifalias"], check=False).stdout.strip()
            if alias != TUNNEL_ALIAS:
                raise ForeignConflict("tunnel name is owned by another component")
            mode = tunnel.stdout.split()[1] if len(tunnel.stdout.split()) > 1 else ""
            if "ipip6" not in mode and "ip/ipv6" not in mode:
                raise ForeignConflict("owned tunnel has an unsupported mode")
            old_tunnel_local = _token_after(tunnel.stdout, "local")
            old_tunnel_remote = _token_after(tunnel.stdout, "remote")
            old_tunnel_device = _optional_token_after(tunnel.stdout, "dev")
            if old_tunnel_local != local or old_tunnel_remote != cfg.br_ipv6 or old_tunnel_device != capabilities.wan_interface:
                actions.append(Action(
                    "owned-tunnel-endpoint-changed",
                    ("ip", "-6", "tunnel", "change", cfg.tunnel_name, "mode", "ipip6", "local", local, "remote", cfg.br_ipv6, "dev", capabilities.wan_interface, "encaplimit", "none"),
                    ("ip", "-6", "tunnel", "change", cfg.tunnel_name, "mode", "ipip6", "local", old_tunnel_local, "remote", old_tunnel_remote, *(("dev", old_tunnel_device) if old_tunnel_device else ()), "encaplimit", "none"),
                ))

        actions.extend(self._tunnel_address_actions(tunnel_created))
        tunnel_link = self.runner.run(["ip", "-o", "link", "show", "dev", cfg.tunnel_name], check=False)
        if tunnel_link.returncode != 0 or f"mtu {cfg.tunnel_mtu}" not in tunnel_link.stdout or "UP" not in tunnel_link.stdout:
            inverse = None
            if not tunnel_created and tunnel_link.returncode == 0:
                old_mtu = _token_after(tunnel_link.stdout, "mtu")
                old_state = "up" if "UP" in tunnel_link.stdout else "down"
                inverse = ("ip", "link", "set", "dev", cfg.tunnel_name, "mtu", old_mtu, old_state)
            actions.append(Action("tunnel-link-converge", ("ip", "link", "set", "dev", cfg.tunnel_name, "mtu", str(cfg.tunnel_mtu), "up"), inverse))

        actions.extend(self._route_rule_actions(resources))
        actions.extend(self._firewall_actions(capabilities))
        actions.extend(self._endpoint_cleanup_actions(capabilities))
        actions.extend(router_actions)
        return capabilities, resources, actions

    def _tunnel_address_actions(self, tunnel_created: bool) -> list[Action]:
        cfg = self.config
        desired = f"{cfg.static_ipv4}/32"
        if tunnel_created:
            return [Action("fixed-ipv4-missing", ("ip", "-4", "address", "replace", desired, "dev", cfg.tunnel_name), ("ip", "-4", "address", "del", desired, "dev", cfg.tunnel_name))]
        result = self.runner.run(["ip", "-4", "-o", "address", "show", "dev", cfg.tunnel_name], check=False)
        if result.returncode != 0:
            raise PrerequisiteUnavailable("owned tunnel address inspection failed")
        addresses = {fields[fields.index("inet") + 1] for line in result.stdout.splitlines() if "inet" in (fields := line.split())}
        runtime = self.state.read(self.state.runtime_path) or {}
        old_static = runtime.get("static_ipv4")
        allowed_old = f"{old_static}/32" if isinstance(old_static, str) else None
        unknown = addresses - {desired} - ({allowed_old} if allowed_old else set())
        if unknown:
            raise ForeignConflict("owned tunnel contains an unknown IPv4 address")
        actions: list[Action] = []
        if desired not in addresses:
            actions.append(Action("fixed-ipv4-missing", ("ip", "-4", "address", "replace", desired, "dev", cfg.tunnel_name), ("ip", "-4", "address", "del", desired, "dev", cfg.tunnel_name)))
        if allowed_old and allowed_old != desired and allowed_old in addresses:
            actions.append(Action("obsolete-fixed-ipv4", ("ip", "-4", "address", "del", allowed_old, "dev", cfg.tunnel_name), ("ip", "-4", "address", "add", allowed_old, "dev", cfg.tunnel_name)))
        return actions

    def _endpoint_cleanup_actions(self, capabilities: Capabilities) -> list[Action]:
        runtime = self.state.read(self.state.runtime_path)
        if not runtime:
            return []
        old_local = runtime.get("local_endpoint")
        old_wan = runtime.get("wan_interface")
        if not isinstance(old_local, str) or not isinstance(old_wan, str):
            return []
        if old_local == capabilities.local_endpoint and old_wan == capabilities.wan_interface:
            return []
        actions: list[Action] = []
        if self.config.outer_ipip_allow and old_local != capabilities.local_endpoint:
            rule = ("-s", f"{self.config.br_ipv6}/128", "-d", f"{old_local}/128", "-p", "4", "-m", "comment", "--comment", FIREWALL_TAG, "-j", "ACCEPT")
            if self.runner.run(_xtables_command("ip6tables", "-C", capabilities.v6_input_chain, *rule), check=False).returncode == 0:
                actions.append(Action(
                    "obsolete-outer-rule",
                    tuple(_xtables_command("ip6tables", "-D", capabilities.v6_input_chain, *rule)),
                    tuple(_xtables_command("ip6tables", "-A", capabilities.v6_input_chain, *rule)),
                ))
        if self._address_exists(old_wan, f"{old_local}/128", 6):
            actions.append(Action("obsolete-endpoint-address", ("ip", "-6", "address", "del", f"{old_local}/128", "dev", old_wan), ("ip", "-6", "address", "add", f"{old_local}/128", "dev", old_wan)))
        return actions

    def _address_exists(self, interface: str, address: str, family: int) -> bool:
        output = self.runner.run(["ip", f"-{family}", "-o", "address", "show", "dev", interface], check=False)
        return output.returncode == 0 and any(address == token for token in output.stdout.split())

    def _route_rule_actions(self, resources: Resources) -> list[Action]:
        actions: list[Action] = []
        table = str(resources.route_table)
        cfg = self.config
        routes = self.runner.run(["ip", "-4", "route", "show", "table", table], check=False).stdout
        expected_routes = {f"default dev {cfg.tunnel_name}"}
        expected_routes.update(f"{network.ipv4_cidr} dev {network.interface}" for network in cfg.routed_networks)
        for line in routes.splitlines():
            if not any(_route_matches(line, expected) for expected in expected_routes):
                raise ForeignConflict("allocated route table contains a foreign route")
        if not any(_route_matches(line, f"default dev {cfg.tunnel_name}") for line in routes.splitlines()):
            actions.append(Action("default-route-missing", ("ip", "-4", "route", "replace", "table", table, "default", "dev", cfg.tunnel_name), ("ip", "-4", "route", "del", "table", table, "default", "dev", cfg.tunnel_name)))
        rules = self.runner.run(["ip", "-4", "rule", "show"]).stdout
        for offset, network in enumerate(cfg.routed_networks):
            route_prefix = f"{network.ipv4_cidr} dev {network.interface}"
            if not any(_route_matches(line, route_prefix) for line in routes.splitlines()):
                actions.append(Action("connected-route-missing", ("ip", "-4", "route", "replace", "table", table, network.ipv4_cidr, "dev", network.interface), ("ip", "-4", "route", "del", "table", table, network.ipv4_cidr, "dev", network.interface)))
            pref = resources.rule_priority_base + offset
            matching_pref = [line for line in rules.splitlines() if line.startswith(f"{pref}:")]
            expected = f"{pref}:\tfrom {network.ipv4_cidr} iif {network.interface} lookup {table}"
            if matching_pref and not any(_rule_equivalent(line, pref, network, resources.route_table) for line in matching_pref):
                raise ForeignConflict("allocated policy-rule priority is foreign")
            if not matching_pref:
                actions.append(Action("policy-rule-missing", ("ip", "-4", "rule", "add", "pref", str(pref), "from", network.ipv4_cidr, "iif", network.interface, "lookup", table), ("ip", "-4", "rule", "del", "pref", str(pref), "from", network.ipv4_cidr, "iif", network.interface, "lookup", table)))
        router_pref = resources.rule_priority_base + len(cfg.routed_networks)
        matching_router_pref = [line for line in rules.splitlines() if line.startswith(f"{router_pref}:")]
        if matching_router_pref and not any(
            _source_rule_equivalent(line, router_pref, cfg.static_ipv4, resources.route_table)
            for line in matching_router_pref
        ):
            raise ForeignConflict("allocated router-source policy-rule priority is foreign")
        if not matching_router_pref:
            actions.append(Action(
                "router-source-policy-rule-missing",
                ("ip", "-4", "rule", "add", "pref", str(router_pref), "from", f"{cfg.static_ipv4}/32", "lookup", table),
                ("ip", "-4", "rule", "del", "pref", str(router_pref), "from", f"{cfg.static_ipv4}/32", "lookup", table),
            ))
        return actions

    def _firewall_actions(self, capabilities: Capabilities) -> list[Action]:
        cfg = self.config
        actions: list[Action] = []
        expected: dict[tuple[str, tuple[str, ...], str], list[tuple[str, ...]]] = {}
        if self.router and cfg.wan_integration == 'standalone':
            from .wan_policy import DNS_CHAIN, validate
            for chain, rule in validate(self.runner, self.router.identity['interface'], cfg.tunnel_name):
                expected.setdefault(("iptables", (), chain), []).append(rule)
                actions.extend(self._ensure_xtables("iptables", (), chain, rule, "wan-policy-dispatch-missing", insert_first=chain == DNS_CHAIN))
        if self.router:
            rule = self.router.dns_snat_rule()
            expected.setdefault(("iptables", ("-t", "nat"), capabilities.nat_chain), []).append(rule)
            actions.extend(self._ensure_xtables("iptables", ("-t", "nat"), capabilities.nat_chain, rule, "router-dns-snat-missing"))
        for network in cfg.routed_networks:
            rule = ("-s", network.ipv4_cidr, "-o", cfg.tunnel_name, "-m", "comment", "--comment", FIREWALL_TAG, "-j", "SNAT", "--to-source", cfg.static_ipv4)
            expected.setdefault(("iptables", ("-t", "nat"), capabilities.nat_chain), []).append(rule)
            actions.extend(self._ensure_xtables("iptables", ("-t", "nat"), capabilities.nat_chain, rule, "snat-missing"))
        for chain, direction in (("FORWARD", "-o"), ("FORWARD", "-i"), ("OUTPUT", "-o")):
            rule = (direction, cfg.tunnel_name, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-m", "comment", "--comment", FIREWALL_TAG, "-j", "TCPMSS", "--set-mss", str(cfg.tcp_mss))
            expected.setdefault(("iptables", ("-t", "mangle"), chain), []).append(rule)
            actions.extend(self._ensure_xtables("iptables", ("-t", "mangle"), chain, rule, "mss-missing"))
        if cfg.outer_ipip_allow:
            rule = ("-s", f"{cfg.br_ipv6}/128", "-d", f"{capabilities.local_endpoint}/128", "-p", "4", "-m", "comment", "--comment", FIREWALL_TAG, "-j", "ACCEPT")
            expected.setdefault(("ip6tables", (), capabilities.v6_input_chain), []).append(rule)
            actions.extend(self._ensure_xtables("ip6tables", (), capabilities.v6_input_chain, rule, "outer-rule-missing", insert_first=cfg.wan_integration == 'unifi-managed'))
        allowed_obsolete: set[tuple[str, tuple[str, ...], str, tuple[str, ...]]] = set()
        runtime = self.state.read(self.state.runtime_path)
        old_local = runtime.get("local_endpoint") if runtime else None
        if isinstance(old_local, str) and old_local != capabilities.local_endpoint:
            old_rule = ("-s", f"{cfg.br_ipv6}/128", "-d", f"{old_local}/128", "-p", "4", "-m", "comment", "--comment", FIREWALL_TAG, "-j", "ACCEPT")
            allowed_obsolete.add(("ip6tables", (), capabilities.v6_input_chain, old_rule))
        self._validate_global_firewall_ownership(expected, allowed_obsolete)
        actions.extend(self._firewall_duplicate_actions(expected, allowed_obsolete))
        return actions

    def _validate_global_firewall_ownership(
        self,
        expected: dict[tuple[str, tuple[str, ...], str], list[tuple[str, ...]]],
        allowed_obsolete: set[tuple[str, tuple[str, ...], str, tuple[str, ...]]],
    ) -> None:
        allowed: list[tuple[str, str, tuple[str, ...]]] = []
        for (binary, prefix, chain), rules in expected.items():
            table = prefix[1] if prefix else "filter"
            allowed.extend((binary, table, ("-A", chain, *rule)) for rule in rules)
        for binary, prefix, chain, rule in allowed_obsolete:
            allowed.append((binary, prefix[1] if prefix else "filter", ("-A", chain, *rule)))
        for binary in ("iptables", "ip6tables"):
            result = self._firewall_inventory(binary)
            table: str | None = None
            for raw_line in result.stdout.splitlines():
                if raw_line.startswith("*"):
                    table = raw_line[1:]
                    continue
                if raw_line == "COMMIT":
                    table = None
                    continue
                try:
                    tokens = tuple(shlex.split(raw_line))
                except ValueError as exc:
                    raise ForeignConflict("project firewall inventory cannot be parsed") from exc
                if not _has_firewall_tag(tokens):
                    continue
                if table is None or not any(
                    item_binary == binary and item_table == table and _xtables_equivalent(tokens, item_rule)
                    for item_binary, item_table, item_rule in allowed
                ):
                    raise ForeignConflict("project firewall tag exists outside owned resources")

    def _firewall_inventory(self, binary: str) -> subprocess.CompletedProcess[str]:
        result = None
        for delay in (0, 1, 2, 5):
            if delay:
                time.sleep(delay)
            result = self.runner.run([f"{binary}-save"], check=False)
            if result.returncode == 0 and result.stdout.strip():
                return result
        raise PrerequisiteUnavailable("authoritative firewall inventory is unavailable")

    def _firewall_duplicate_actions(
        self,
        expected: dict[tuple[str, tuple[str, ...], str], list[tuple[str, ...]]],
        allowed_obsolete: set[tuple[str, tuple[str, ...], str, tuple[str, ...]]],
    ) -> list[Action]:
        actions: list[Action] = []
        for (binary, prefix, chain), rules in expected.items():
            output = self.runner.run(_xtables_command(binary, *prefix, "-S", chain), check=False)
            if output.returncode != 0:
                raise PrerequisiteUnavailable("firewall chain inspection failed")
            expected_rules = list(rules)
            counts = [0 for _ in expected_rules]
            for raw_line in output.stdout.splitlines():
                try:
                    actual_tokens = tuple(shlex.split(raw_line))
                except ValueError as exc:
                    raise ForeignConflict("project firewall rule cannot be parsed") from exc
                if not _has_firewall_tag(actual_tokens):
                    continue
                matched = next((index for index, rule in enumerate(expected_rules) if _xtables_equivalent(actual_tokens, ("-A", chain, *rule))), None)
                if matched is None:
                    if any(
                        old_binary == binary and old_prefix == prefix and old_chain == chain
                        and _xtables_equivalent(actual_tokens, ("-A", chain, *old_rule))
                        for old_binary, old_prefix, old_chain, old_rule in allowed_obsolete
                    ):
                        continue
                    raise ForeignConflict("project firewall tag has an unknown rule shape")
                counts[matched] += 1
            for index, count in enumerate(counts):
                for _ in range(max(0, count - 1)):
                    rule = expected_rules[index]
                    restore = ("-I", chain, "1") if binary == 'iptables' and not prefix and chain == 'UBIOS_DNS_PBR_JUMP' else ("-A", chain)
                    actions.append(Action(
                        "duplicate-firewall-rule",
                        tuple(_xtables_command(binary, *prefix, "-D", chain, *rule)),
                        tuple(_xtables_command(binary, *prefix, *restore, *rule)),
                    ))
        return actions

    def _ensure_xtables(self, binary: str, prefix: tuple[str, ...], chain: str, rule: tuple[str, ...], reason: str, *, insert_first: bool = False) -> list[Action]:
        checked = self.runner.run(_xtables_command(binary, *prefix, "-C", chain, *rule), check=False)
        if checked.returncode == 0:
            return []
        insertion = ("-I", chain, "1") if insert_first else ("-A", chain)
        return [Action(reason, tuple(_xtables_command(binary, *prefix, *insertion, *rule)), tuple(_xtables_command(binary, *prefix, "-D", chain, *rule)))]

    def _settle_delays(self, actions: list[Action]) -> tuple[int, ...]:
        # Standalone mode only needs a delayed check after a monitor update.
        return (10,) if any(action.reason == 'wan-monitor-binding-drift' for action in actions) else ()

    def reconcile(self) -> dict[str, Any]:
        try:
            lock = self.state.lock()
        except BlockingIOError as exc:
            raise PrerequisiteUnavailable("another operation is in progress") from exc
        with lock:
            try:
                capabilities, resources, actions = self.plan()
                old_runtime = self.state.read(self.state.runtime_path)
            except JpixError as exc:
                reason = _reason_code(exc)
                self._record_failure(reason)
                self.state.quarantine(reason)
                self._notify_webhook(reason, "quarantined")
                raise
            inverses: list[Action] = []
            self.state.begin_transaction(actions)
            previous_handlers: dict[int, Any] = {}
            def interrupted(_signum, _frame):
                raise MutationError("interrupted")
            for signum in (signal.SIGTERM, signal.SIGINT):
                previous_handlers[signum] = signal.getsignal(signum)
                signal.signal(signum, interrupted)
            try:
                for completed, action in enumerate(actions, start=1):
                    if action.inverse or action.undo_callback:
                        inverses.append(action)
                    if action.apply_callback:
                        action.apply_callback()
                    else:
                        self.runner.run(action.command)
                    self.state.transaction_progress(completed)
                for delay in self._settle_delays(actions):
                    # Managed WAN restores its endpoint immediately, then checks
                    # for late asynchronous rebuilds under the same lock/journal.
                    if delay:
                        time.sleep(delay)
                    capabilities, resources, settled = self.plan()
                    if any(action.apply_callback for action in settled):
                        raise MutationError('monitor-configuration-unstable')
                    journal = self.state.read(self.state.journal_path) or {}
                    journal['actions'] = [action.reason for action in [*actions, *settled]]
                    self.state.write(self.state.journal_path, journal)
                    for action in settled:
                        if action.inverse:
                            inverses.append(action)
                        self.runner.run(action.command)
                        actions.append(action)
                        self.state.transaction_progress(len(actions))
                runtime = self._runtime(capabilities, resources)
                self._health_check(capabilities, resources)
                if old_runtime:
                    self.state.write(self.state.previous_path, old_runtime)
                self.state.write(self.state.runtime_path, runtime)
                self.state.write(self.state.health_path, {"schema": 1, "status": "healthy", "at": int(time.time()), "repairs": len(actions)})
                recovered = self.state.quarantine_path.exists()
                self.state.clear_quarantine()
                self.state.finish_transaction("verified")
                provider = "not-configured"
                pending = self.state.read(self.state.notification_path)
                endpoint_changed = not old_runtime or old_runtime.get("local_endpoint") != capabilities.local_endpoint
                if endpoint_changed or pending:
                    try:
                        provider = self._notify_provider(capabilities.local_endpoint)
                        self.state.notification_path.unlink(missing_ok=True)
                        if pending:
                            self._notify_webhook("provider-update-recovered", "healthy")
                    except JpixError:
                        provider = "deferred"
                        self.state.write(self.state.notification_path, {
                            "schema": 1, "reason": "provider-update-pending", "at": int(time.time())
                        })
                        if not pending:
                            self._notify_webhook("provider-update-pending", "degraded")
                if actions or recovered:
                    self._notify_webhook("reconciled", "healthy")
                return {"status": "healthy", "repairs": len(actions), "provider_update": provider, "capabilities": capabilities.share_safe()}
            except Exception as exc:
                rollback_failed = False
                for inverse in reversed(inverses):
                    try:
                        if inverse.undo_callback:
                            inverse.undo_callback()
                        elif inverse.inverse:
                            self.runner.run(inverse.inverse)
                    except Exception:
                        rollback_failed = True
                reason = "rollback-failed" if rollback_failed else _reason_code(exc)
                self.state.finish_transaction(reason)
                self._record_failure(reason)
                self.state.quarantine(reason)
                self._notify_webhook(reason, "quarantined")
                raise MutationError(reason) from exc
            finally:
                for signum, handler in previous_handlers.items():
                    signal.signal(signum, handler)

    def _health_check(self, capabilities: Capabilities, resources: Resources) -> None:
        route = self.runner.run(["ip", "-4", "route", "show", "table", str(resources.route_table), "default"], check=False)
        if route.returncode != 0 or not any(_route_matches(line, f"default dev {self.config.tunnel_name}") for line in route.stdout.splitlines()):
            raise MutationError("route-health-failed")
        for family, interface, destination, failure in (
            ("-4", self.config.tunnel_name, "1.1.1.1", "ipv4-connectivity-health-failed"),
            ("-6", capabilities.wan_interface, "2606:4700:4700::1111", "ipv6-connectivity-health-failed"),
        ):
            for delay in (0, 2, 5):
                if delay:
                    time.sleep(delay)
                result = self.runner.run(["ping", family, "-I", interface, "-c", "1", "-W", "3", destination], check=False)
                if result.returncode == 0:
                    break
            else:
                raise MutationError(failure)
        if self.router:
            self.router.health_check()
        if self.router and self.config.wan_integration == 'standalone':
            from .wan_policy import validate
            for chain, rule in validate(self.runner, self.router.identity['interface'], self.config.tunnel_name):
                if self.runner.run(_xtables_command('iptables', '-C', chain, *rule), check=False).returncode:
                    raise MutationError('wan-policy-health-failed')

    def _notify_provider(self, local_endpoint: str) -> str:
        if not self.config.provider_url:
            return "not-configured"
        parsed = urlparse(self.config.provider_url)
        if not parsed.hostname:
            raise PrerequisiteUnavailable("provider update URL is invalid")
        if parsed.scheme == "http" and (
            not self.config.provider_allow_insecure_http
            or parsed.hostname != self.config.provider_insecure_http_host
        ):
            raise PrerequisiteUnavailable("provider HTTP opt-in does not match")
        if parsed.scheme not in {"http", "https"}:
            raise PrerequisiteUnavailable("provider update scheme is unsupported")
        if not self.config.credentials_file:
            raise ConfigError("provider credentials file is required")
        _require_private_file(self.config.credentials_file, "provider credentials")
        try:
            credentials = json.loads(self.config.credentials_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigError("provider credentials are invalid") from exc
        if set(credentials) != {"provider_username", "provider_password"} or not all(isinstance(credentials[key], str) and credentials[key] for key in credentials):
            raise ConfigError("provider credentials are invalid")
        if any(any(character in value for character in "\r\n\0") for value in credentials.values()):
            raise ConfigError("provider credentials contain unsupported control characters")
        self.state.ensure()
        temporary_dir = Path(tempfile.mkdtemp(prefix=".provider-update.", dir=self.state.state_dir))
        temporary_dir.chmod(0o700)
        curl_config = temporary_dir / "curl.conf"
        body = temporary_dir / "body"
        try:
            with curl_config.open("x", encoding="utf-8") as stream:
                stream.write(f'url = "{_curl_config_value(self.config.provider_url)}"\n')
                stream.write('get\n')
                stream.write(f'data-urlencode = "user={_curl_config_value(credentials["provider_username"])}"\n')
                stream.write(f'data-urlencode = "pass={_curl_config_value(credentials["provider_password"])}"\n')
            curl_config.chmod(0o600)
            body.touch(mode=0o600)
            protocol = "=http" if parsed.scheme == "http" else "=https"
            result = None
            provider_succeeded = False
            for delay in (0, 5, 15):
                if delay:
                    time.sleep(delay)
                result = self.runner.run([
                    "curl", "--config", str(curl_config), "--proto", protocol,
                    "--proto-redir", protocol, "--ipv6", "--silent", "--show-error",
                    "--connect-timeout", "10", "--max-time", "30",
                    "--interface", local_endpoint, "--output", str(body),
                    "--write-out", "%{http_code}",
                ], check=False)
                if result.returncode == 0 and result.stdout == "200" and _provider_body_success(body):
                    provider_succeeded = True
                    break
            assert result is not None
        finally:
            for target in (curl_config, body):
                target.unlink(missing_ok=True)
            temporary_dir.rmdir()
        if not provider_succeeded:
            raise PrerequisiteUnavailable("provider update failed")
        return "success"

    def _notify_webhook(self, reason: str, status: str) -> None:
        if not self.config.webhook_url:
            return
        payload = json.dumps({
            "schema": 1,
            "project": PROJECT,
            "version": "2",
            "model": "udm-pro-family",
            "status": status,
            "reason": reason,
        }, separators=(",", ":"))
        self.state.ensure()
        descriptor, temporary = tempfile.mkstemp(prefix=".webhook-curl.", dir=self.state.state_dir)
        curl_config = Path(temporary)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(f'url = "{_curl_config_value(self.config.webhook_url)}"\n')
            curl_config.chmod(0o600)
            self.runner.run([
                "curl", "--config", str(curl_config), "--fail", "--silent",
                "--show-error", "--max-time", "10", "--header",
                "Content-Type: application/json", "--data", payload,
                "--output", "/dev/null",
            ], check=False)
        finally:
            curl_config.unlink(missing_ok=True)

    def _runtime(self, capabilities: Capabilities, resources: Resources) -> dict[str, Any]:
        return {
            "schema": 2,
            "generation": int(time.time()),
            "config_digest": config_digest(self.config),
            "resources": {"route_table": resources.route_table, "rule_priority_base": resources.rule_priority_base},
            "wan_interface": capabilities.wan_interface,
            "endpoint_interface": capabilities.endpoint_interface,
            "endpoint_prefix": capabilities.endpoint_prefix,
            "local_endpoint": capabilities.local_endpoint,
            "tunnel_name": self.config.tunnel_name,
            "static_ipv4": self.config.static_ipv4,
            "nat_chain": capabilities.nat_chain,
            "v6_input_chain": capabilities.v6_input_chain,
            "wan_policy_integration": 2 if self.config.router_recovery_enabled and self.config.wan_integration == 'standalone' else 0,
            "integration_mode": self.config.wan_integration,
        }

    def deactivate(self) -> None:
        try:
            lock = self.state.lock()
        except BlockingIOError as exc:
            raise PrerequisiteUnavailable("another operation is in progress") from exc
        with lock:
            runtime = self.state.read(self.state.runtime_path)
            if not runtime:
                return
            required = {"local_endpoint", "wan_interface", "resources", "tunnel_name", "nat_chain", "v6_input_chain"}
            if not required.issubset(runtime) or runtime.get("tunnel_name") != self.config.tunnel_name:
                raise ForeignConflict("runtime ownership state is incomplete")
            alias = self.runner.run(["cat", f"/sys/class/net/{self.config.tunnel_name}/ifalias"], check=False)
            if alias.returncode != 0 or alias.stdout.strip() != TUNNEL_ALIAS:
                raise ForeignConflict("project tunnel ownership cannot be verified")
            resources = runtime["resources"]
            table = str(resources["route_table"])
            priority = int(resources["rule_priority_base"])
            local = str(runtime["local_endpoint"])
            wan = _interface(runtime["wan_interface"], "runtime WAN")
            failures = 0

            if self.config.router_recovery_enabled:
                from .router import RouterRecovery
                router = RouterRecovery(self.config, self.runner, Resources(int(table), priority), self.state)
                router.deactivate()
                failures += self._delete_all_xtables("iptables", ("-t", "nat"), str(runtime["nat_chain"]), router.dns_snat_rule())
            elif (self.state.state_dir / "router-recovery.json").exists():
                raise ForeignConflict("router recovery must remain enabled during deactivation")

            for network in self.config.routed_networks:
                rule = ("-s", network.ipv4_cidr, "-o", self.config.tunnel_name, "-m", "comment", "--comment", FIREWALL_TAG, "-j", "SNAT", "--to-source", self.config.static_ipv4)
                failures += self._delete_all_xtables("iptables", ("-t", "nat"), str(runtime["nat_chain"]), rule)
            for chain, direction in (("FORWARD", "-o"), ("FORWARD", "-i"), ("OUTPUT", "-o")):
                rule = (direction, self.config.tunnel_name, "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-m", "comment", "--comment", FIREWALL_TAG, "-j", "TCPMSS", "--set-mss", str(self.config.tcp_mss))
                failures += self._delete_all_xtables("iptables", ("-t", "mangle"), chain, rule)
            if self.config.outer_ipip_allow:
                rule = ("-s", f"{self.config.br_ipv6}/128", "-d", f"{local}/128", "-p", "4", "-m", "comment", "--comment", FIREWALL_TAG, "-j", "ACCEPT")
                failures += self._delete_all_xtables("ip6tables", (), str(runtime["v6_input_chain"]), rule)
            for offset, network in enumerate(self.config.routed_networks):
                command = ["ip", "-4", "rule", "del", "pref", str(priority + offset), "from", network.ipv4_cidr, "iif", network.interface, "lookup", table]
                if self.runner.run(command, check=False).returncode not in {0, 2}:
                    failures += 1
                command = ["ip", "-4", "route", "del", "table", table, network.ipv4_cidr, "dev", network.interface]
                if self.runner.run(command, check=False).returncode not in {0, 2}:
                    failures += 1
            router_priority = priority + len(self.config.routed_networks)
            command = ["ip", "-4", "rule", "del", "pref", str(router_priority), "from", f"{self.config.static_ipv4}/32", "lookup", table]
            if self.runner.run(command, check=False).returncode not in {0, 2}:
                failures += 1
            if self.runner.run(["ip", "-4", "route", "del", "table", table, "default", "dev", self.config.tunnel_name], check=False).returncode not in {0, 2}:
                failures += 1
            if self.runner.run(["ip", "-6", "tunnel", "del", self.config.tunnel_name], check=False).returncode != 0:
                failures += 1
            else:
                # Keep WAN filtering in place until the data-plane device is gone.
                from .wan_policy import rules as wan_policy_rules
                for chain, rule in wan_policy_rules(self.config.tunnel_name):
                    failures += self._delete_all_xtables('iptables', (), chain, rule)
            if self.runner.run(["ip", "-6", "address", "del", f"{local}/128", "dev", wan], check=False).returncode not in {0, 2}:
                failures += 1
            if failures:
                self.state.quarantine("deactivation-failed")
                raise MutationError("deactivation-failed")
            self.state.runtime_path.unlink(missing_ok=True)
            (self.state.state_dir / "router-recovery.json").unlink(missing_ok=True)
            self.state.notification_path.unlink(missing_ok=True)
            self.state.write(self.state.health_path, {"schema": 1, "status": "inactive", "at": int(time.time())})
            self.state.clear_quarantine()

    def _delete_all_xtables(self, binary: str, prefix: tuple[str, ...], chain: str, rule: tuple[str, ...]) -> int:
        for _ in range(8):
            if self.runner.run(_xtables_command(binary, *prefix, "-C", chain, *rule), check=False).returncode != 0:
                return 0
            if self.runner.run(_xtables_command(binary, *prefix, "-D", chain, *rule), check=False).returncode != 0:
                return 1
        return 1

    def _record_failure(self, reason: str) -> None:
        previous = self.state.read(self.state.health_path) or {}
        failures = int(previous.get("consecutive_failures", 0)) + 1
        self.state.write(self.state.health_path, {
            "schema": 1,
            "status": "failed",
            "reason": reason,
            "at": int(time.time()),
            "consecutive_failures": failures,
        })

    def status(self) -> dict[str, Any]:
        quarantine = self.state.read(self.state.quarantine_path)
        health = self.state.read(self.state.health_path)
        try:
            capabilities, resources, actions = self.plan()
            return {
                "status": "quarantined" if quarantine else ("healthy" if not actions else "drifted"),
                "reason": quarantine.get("reason") if quarantine else None,
                "pending_repairs": len(actions),
                "capabilities": capabilities.share_safe(),
                "resources": {"route_table": resources.route_table, "rule_priority_base": resources.rule_priority_base},
                "last_health": health,
            }
        except JpixError as exc:
            return {"status": "unavailable", "reason": _reason_code(exc), "pending_repairs": None, "last_health": health}


def config_digest(config: Config) -> str:
    safe = {
        "schema": config.schema_version,
        "service": config.service,
        "static_ipv4": config.static_ipv4,
        "br_ipv6": config.br_ipv6,
        "iid": config.iid,
        "endpoint_interface": config.endpoint_interface,
        "endpoint_ipv4_cidr": config.endpoint_ipv4_cidr,
        "routed_networks": [network.__dict__ for network in config.routed_networks],
        "tunnel": [config.tunnel_name, config.tunnel_mtu, config.tcp_mss],
        "router_recovery": config.router_recovery_enabled,
        "integration_mode": config.wan_integration,
    }
    return hashlib.sha256(json.dumps(safe, sort_keys=True).encode()).hexdigest()


def _reason_code(exc: Exception) -> str:
    if isinstance(exc, ForeignConflict):
        return "foreign-conflict"
    if isinstance(exc, PrerequisiteUnavailable):
        return "prerequisite-unavailable"
    if isinstance(exc, ConfigError):
        return "invalid-config"
    if isinstance(exc, MutationError):
        return str(exc)
    return "operation-failed"


def _rule_equivalent(line: str, pref: int, network: RoutedNetwork, table: int) -> bool:
    fields = line.replace(":", " ").split()
    expected = [str(pref), "from", network.ipv4_cidr, "iif", network.interface, "lookup", str(table)]
    return fields == expected


def _source_rule_equivalent(line: str, pref: int, source: str, table: int) -> bool:
    fields = line.replace(":", " ").split()
    if len(fields) != 5 or fields[:2] != [str(pref), "from"] or fields[3:] != ["lookup", str(table)]:
        return False
    try:
        actual = ipaddress.ip_network(fields[2], strict=False)
    except ValueError:
        return False
    return actual == ipaddress.ip_network(f"{source}/32")


def _route_matches(line: str, expected: str) -> bool:
    fields = line.split()
    wanted = expected.split()
    return fields[:len(wanted)] == wanted


def _xtables_equivalent(actual: Sequence[str], expected: Sequence[str]) -> bool:
    def normalize(tokens: Sequence[str]) -> tuple[str, ...]:
        result: list[str] = []
        index = 0
        while index < len(tokens):
            if tokens[index] == "-m" and index + 1 < len(tokens) and tokens[index + 1] in {"comment", "tcp", "udp"}:
                index += 2
                continue
            token = "-p" if tokens[index] == "--protocol" else tokens[index]
            if result and result[-1] == "-p" and token in {"4", "ipencap", "ipv4"}:
                token = "4"
            result.append(token)
            index += 1
        return tuple(result)
    return normalize(actual) == normalize(expected)


def _has_firewall_tag(tokens: Sequence[str]) -> bool:
    return any(
        token == "--comment" and index + 1 < len(tokens) and tokens[index + 1] == FIREWALL_TAG
        for index, token in enumerate(tokens)
    )


def _token_after(text: str, token: str) -> str:
    fields = text.split()
    try:
        return fields[fields.index(token) + 1]
    except (ValueError, IndexError) as exc:
        raise PrerequisiteUnavailable(f"required {token} token is absent") from exc


def _optional_token_after(text: str, token: str) -> str | None:
    fields = text.split()
    try:
        return fields[fields.index(token) + 1]
    except (ValueError, IndexError):
        return None


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{field} must be an object")
    return value


def _reject_unknown(value: dict[str, Any], allowed: set[str], field: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ConfigError(f"{field} contains unknown fields")


def _interface(value: Any, field: str) -> str:
    if not isinstance(value, str) or not IFACE_RE.fullmatch(value):
        raise ConfigError(f"{field} is invalid")
    return value


def _ipv4_address(value: Any, field: str) -> ipaddress.IPv4Address:
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError as exc:
        raise ConfigError(f"{field} is invalid") from exc
    if not isinstance(parsed, ipaddress.IPv4Address):
        raise ConfigError(f"{field} must be IPv4")
    return parsed


def _ipv6_address(value: Any, field: str) -> ipaddress.IPv6Address:
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError as exc:
        raise ConfigError(f"{field} is invalid") from exc
    if not isinstance(parsed, ipaddress.IPv6Address):
        raise ConfigError(f"{field} must be IPv6")
    return parsed


def _private_ipv4_network(value: Any, field: str) -> ipaddress.IPv4Network:
    try:
        parsed = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise ConfigError(f"{field} is invalid") from exc
    if not isinstance(parsed, ipaddress.IPv4Network) or not parsed.is_private:
        raise ConfigError(f"{field} must be canonical private IPv4")
    return parsed


def _iid(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9A-Fa-f]{4}(?::[0-9A-Fa-f]{4}){3}", value):
        raise ConfigError("iid must contain four full hextets")
    return value.lower()


def _integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not minimum <= value <= maximum:
        raise ConfigError(f"{field} is out of range")
    return value


def _optional_integer(value: Any, field: str, minimum: int, maximum: int) -> int | None:
    if value is None:
        return None
    return _integer(value, field, minimum, maximum)


def _curl_config_value(value: str) -> str:
    if any(character in value for character in "\r\n\0"):
        raise ConfigError("URL or credential contains unsupported control characters")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _xtables_command(binary: str, *arguments: str) -> list[str]:
    return [binary, "-w", "5", *arguments]


def _provider_body_success(path: Path) -> bool:
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            value = line.strip()
            if not value:
                continue
            return not re.match(r"^(NG|ERROR|FAIL)(?:[\s:]|$)", value, re.IGNORECASE)
    except OSError:
        return False
    return True


def _require_private_file(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ConfigError(f"{label} is unreadable") from exc
    if path.is_symlink() or not path.is_file() or metadata.st_mode & 0o077:
        raise ConfigError(f"{label} must be a private regular file")
    if os.geteuid() == 0 and metadata.st_uid != 0:
        raise ConfigError(f"{label} must be root-owned")
