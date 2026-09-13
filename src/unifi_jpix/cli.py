"""Command-line interface for the v2 reconciler."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any

from . import __version__
from .core import Config, DEFAULT_ROOT, JpixError, Reconciler, Runner, SUPPORTED_MODELS, _reason_code
from .release import ReleaseManager


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="unifi-jpix")
    result.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    result.add_argument("--config", type=Path)
    result.add_argument("--version", action="version", version=__version__)
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("discover")
    commands.add_parser("check")
    commands.add_parser("plan")
    reconcile = commands.add_parser("reconcile")
    reconcile.add_argument("--retry", action="store_true")
    status = commands.add_parser("status")
    status.add_argument("--json", action="store_true")
    commands.add_parser("doctor")
    commands.add_parser("rollback")
    integrate = commands.add_parser('integrate-wan')
    mode = integrate.add_mutually_exclusive_group(required=True)
    mode.add_argument('--activate', action='store_true')
    mode.add_argument('--recover', action='store_true')
    mode.add_argument('--confirm', action='store_true')
    upgrade = commands.add_parser("upgrade")
    upgrade.add_argument("--release", required=True)
    return result


def _config_path(args: argparse.Namespace) -> Path:
    return args.config or args.root / "config-v2.json"


def _load(args: argparse.Namespace) -> Config:
    return Config.load(_config_path(args))


def _reconciler(config: Config, root: Path):
    if config.wan_integration == 'unifi-managed':
        from .managed import ManagedReconciler
        return ManagedReconciler(config, root)
    return Reconciler(config, root)


def _generic_discover(runner: Runner) -> dict[str, Any]:
    model = runner.run(["ubnt-device-info", "model"]).stdout.strip()
    firmware = runner.run(["ubnt-device-info", "firmware"]).stdout.strip()
    default = runner.run(["ip", "-6", "route", "show", "default"], check=False).stdout
    default_devices = sorted(set(re.findall(r"\bdev ([A-Za-z0-9_.:-]+)", default)))
    bridges = runner.run(["ip", "-d", "link", "show", "type", "bridge"], check=False).stdout
    bridge_names = sorted(set(re.findall(r"^\d+: ([^:@]+)", bridges, re.MULTILINE)))
    routes = runner.run(["ip", "-6", "route", "show", "table", "all", "proto", "kernel"], check=False).stdout
    endpoint_candidates = []
    for bridge in bridge_names:
        count = sum(1 for line in routes.splitlines() if f" dev {bridge} " in f" {line} " and re.search(r"\b[23][0-9A-Fa-f:]+/64\b", line))
        if count == 1:
            endpoint_candidates.append({"interface": bridge, "prefix": "present"})
    ipt = runner.run(["iptables", "--version"], check=False).stdout
    ip6t = runner.run(["ip6tables", "--version"], check=False).stdout
    return {
        "schema": 1,
        "model": model,
        "model_status": SUPPORTED_MODELS.get(model, "unsupported"),
        "firmware": firmware,
        "ipv6_default_devices": default_devices,
        "endpoint_candidates": endpoint_candidates,
        "firewall_backend": "iptables-legacy" if "legacy" in ipt and "legacy" in ip6t else "unsupported",
        "config_template": {
            "schema_version": 2,
            "service": "jpix-v6plus-static-ipv4-one",
            "static_ipv4": "replace-with-contract-value",
            "br_ipv6": "replace-with-contract-value",
            "iid": "replace-with-contract-value",
            "endpoint_network": {"interface": "replace-with-candidate"},
            "routed_networks": [{"interface": "replace-with-lan", "ipv4_cidr": "replace-with-cidr"}],
        },
    }


def _doctor(args: argparse.Namespace) -> dict[str, Any]:
    config_path = _config_path(args)
    reconciler = _reconciler(Config.load(config_path), args.root) if config_path.is_file() else None
    status = reconciler.status() if reconciler else {"status": "unconfigured", "reason": "config-missing"}
    checks: dict[str, str] = {}
    for unit in (
        "unifi-jpix-bootstrap.service", "unifi-jpix-reconcile.timer",
        "unifi-jpix-event-monitor.service",
        "unifi-jpix-udapi.path",
    ):
        installed = Path("/etc/systemd/system") / unit
        checks[f"unit_{unit}"] = "present" if installed.is_file() else "missing"
        active = subprocess.run(["systemctl", "is-enabled", unit], capture_output=True, check=False)
        checks[f"enabled_{unit}"] = "yes" if active.returncode == 0 else "no"
    current = args.root / "current"
    checks["current_release"] = "present" if current.is_symlink() else "missing"
    checks["release_signing_key"] = "present" if (args.root / "release-signing-public.pem").is_file() else "missing"
    if reconciler:
        checks["transaction_journal"] = "present" if reconciler.state.journal_path.is_file() else "not-yet-created"
        checks["provider_notification"] = "pending" if reconciler.state.notification_path.is_file() else "clear"
    else:
        checks["transaction_journal"] = "unknown"
        checks["provider_notification"] = "unknown"
    boot_values = [value for key, value in checks.items() if key.startswith(("unit_", "enabled_", "current_"))]
    checks["boot_persistence"] = "ready" if all(value not in {"missing", "no"} for value in boot_values) else "needs-reinstall"
    return {"status": status, "checks": checks}


def _upgrade(args: argparse.Namespace) -> dict[str, Any]:
    manager = ReleaseManager(args.root)
    selected = manager.upgrade(args.release)
    bootstrap = args.root / "current/scripts/unifi-jpix-bootstrap.sh"
    result = subprocess.run([str(bootstrap)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        try:
            manager.rollback()
        except JpixError as rollback_error:
            raise JpixError("release health check and rollback failed") from rollback_error
        raise JpixError("release health check failed; previous release restored")
    if not (args.root / "current").is_symlink() or os.readlink(args.root / "current") != f"releases/{args.release}":
        raise JpixError("release health check failed; previous release restored")
    manager.mark_verified()
    return {"status": "verified", "release": selected["release"]}


def _rollback(args: argparse.Namespace) -> dict[str, Any]:
    selected = ReleaseManager(args.root).rollback()
    bootstrap = args.root / "current/scripts/unifi-jpix-bootstrap.sh"
    result = subprocess.run([str(bootstrap)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise JpixError("rollback release failed its health check")
    return {"status": "verified", "release": selected["release"], "runtime": "reconciled"}


def _print_result(args: argparse.Namespace, result: dict[str, Any]) -> None:
    if args.command == "status" and not args.json:
        reason = result.get("reason") or "none"
        repairs = result.get("pending_repairs")
        print(f"unifi_jpix status={result.get('status')} reason={reason} pending_repairs={repairs}")
        return
    print(json.dumps(result, indent=2, sort_keys=True))


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == 'integrate-wan':
            from .integration import activate, confirm, recover
            operation = activate if args.activate else recover if args.recover else confirm
            result = operation(args.root)
        elif args.command == "discover" and not _config_path(args).is_file():
            result = _generic_discover(Runner())
        elif args.command == "upgrade":
            result = _upgrade(args)
        elif args.command == "rollback":
            result = _rollback(args)
        elif args.command == "doctor":
            result = _doctor(args)
        else:
            reconciler = _reconciler(_load(args), args.root)
            if args.command == "discover":
                result = reconciler.discover().share_safe()
            elif args.command == "check":
                capabilities, _, _ = reconciler.plan()
                result = {"status": "ready", "capabilities": capabilities.share_safe()}
            elif args.command == "plan":
                capabilities, resources, actions = reconciler.plan()
                result = {"status": "ready", "capabilities": capabilities.share_safe(), "resources": resources.__dict__, "actions": [action.share_safe() for action in actions]}
            elif args.command == "reconcile":
                delays = (0, 5, 15, 60) if args.retry else (0,)
                last: Exception | None = None
                for delay in delays:
                    if delay:
                        time.sleep(delay)
                    try:
                        result = reconciler.reconcile()
                        break
                    except JpixError as exc:
                        last = exc
                else:
                    assert last
                    raise last
            elif args.command == "status":
                result = reconciler.status()
            else:
                raise AssertionError(args.command)
        _print_result(args, result)
        if args.command == "status" and result.get("status") != "healthy":
            return 1
        return 0
    except JpixError as exc:
        print(f"unifi_jpix status=failed reason={_reason_code(exc)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
