from __future__ import annotations

import argparse
import contextlib
import io
from pathlib import Path
import unittest
from unittest import mock

from unifi_jpix.cli import main, parser, _rollback


class CliTests(unittest.TestCase):
    def test_retired_migration_is_rejected_before_any_operation(self):
        with mock.patch("unifi_jpix.cli.subprocess.run") as run, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                main(["migrate-v1", "--activate"])
        self.assertEqual(raised.exception.code, 2)
        run.assert_not_called()

    def test_supported_commands_remain_available(self):
        for arguments in (
            ["discover"], ["check"], ["plan"], ["reconcile", "--retry"],
            ["status", "--json"], ["doctor"], ["rollback"],
            ["upgrade", "--release", "v2.1.0"],
            ["integrate-wan", "--activate"], ["integrate-wan", "--recover"],
            ["integrate-wan", "--confirm"],
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(parser().parse_args(arguments).command, arguments[0])

    def test_rollback_only_bootstraps_the_selected_v2_release(self):
        args = argparse.Namespace(root=Path("/test-root"))
        with mock.patch("unifi_jpix.cli.ReleaseManager") as manager, mock.patch("unifi_jpix.cli.subprocess.run") as run:
            manager.return_value.rollback.return_value = {"release": "v2.0.0"}
            run.return_value.returncode = 0
            self.assertEqual(_rollback(args)["runtime"], "reconciled")
            run.assert_called_once_with(
                ["/test-root/current/scripts/unifi-jpix-bootstrap.sh"],
                capture_output=True, text=True, check=False,
            )


if __name__ == "__main__":
    unittest.main()
