from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from unifi_jpix.cli import _migrate_v1
from unifi_jpix.core import MutationError


class MigrationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        config = self.root / "config"
        config.mkdir()
        (config / "gateway.conf").write_text(
            "STATIC_V4=203.0.113.42\n"
            "BR_V6=2001:db8:ffff::1\n"
            "IID=00cb:0071:2a00:0000\n"
            "ENDPOINT_IF=br0\n",
            encoding="utf-8",
        )
        (config / "routed-networks.conf").write_text("br0 192.168.20.0/24\n", encoding="utf-8")
        self.args = argparse.Namespace(root=self.root, activate=True)

    def test_activation_stops_v1_before_off_and_v2_reconcile(self):
        calls: list[tuple[str, ...]] = []

        def run(command, **_kwargs):
            calls.append(tuple(str(item) for item in command))
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.dict(os.environ, {"UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES": "1"}), \
             mock.patch("unifi_jpix.cli.subprocess.run", side_effect=run), \
             mock.patch("unifi_jpix.cli.Reconciler.reconcile", return_value={"status": "healthy"}):
            result = _migrate_v1(self.args)
        self.assertEqual(result["status"], "migrated")
        self.assertEqual(calls[0][:2], ("systemctl", "stop"))
        self.assertEqual(calls[1][-1], "off")
        self.assertTrue(any(command[:2] == ("systemctl", "disable") for command in calls))
        self.assertTrue(any(command == ("systemctl", "enable", "unifi-jpix-bootstrap.service") for command in calls))
        self.assertTrue(any(command == ("systemctl", "start", "unifi-jpix-bootstrap.service") for command in calls))

    def test_failed_v2_reconcile_reapplies_and_restarts_v1(self):
        calls: list[tuple[str, ...]] = []

        def run(command, **_kwargs):
            calls.append(tuple(str(item) for item in command))
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.dict(os.environ, {"UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES": "1"}), \
             mock.patch("unifi_jpix.cli.subprocess.run", side_effect=run), \
             mock.patch("unifi_jpix.cli.time.sleep"), \
             mock.patch("unifi_jpix.cli.Reconciler.reconcile", side_effect=MutationError("failed")):
            with self.assertRaises(MutationError):
                _migrate_v1(self.args)
        self.assertTrue(any(command[-1] == "apply" for command in calls))
        self.assertTrue(any(command[:3] == ("systemctl", "enable", "--now") for command in calls))


if __name__ == "__main__":
    unittest.main()
