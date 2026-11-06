"""Save update boundaries with fake device replies; no actual device commands."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("tfm_install", Path(__file__).resolve().parents[1] / "scripts/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallSafetyTests(unittest.TestCase):
    def args(self, root):
        app = root / "app.app"
        app.mkdir()
        return argparse.Namespace(app=app, backup=root / "backup", bundle_id="org.example.game", team="ABCDE12345",
                                  device="TEST-UDID", game_closed=True, previous_install=None)

    def test_parent_listing_missing_is_distinct_from_connection_error(self):
        args = argparse.Namespace(device="TEST-UDID", bundle_id="org.example.game")
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(installer, "devicectl", return_value={"files": []}):
                self.assertFalse(installer.save_directory_exists(args, Path(tmp), "before"))
            with patch.object(installer, "devicectl", side_effect=ValueError("connection failed")):
                with self.assertRaisesRegex(ValueError, "connection failed"):
                    installer.save_directory_exists(args, Path(tmp), "before")

    def test_unknown_colliding_app_stops_before_install_or_backup_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(Path(tmp))
            with patch.object(installer, "verify_signed", return_value={}), \
                 patch.object(installer, "devicectl", return_value={"apps": [{"bundleIdentifier": args.bundle_id, "name": "Another App"}]}) as device, \
                 patch.object(installer, "snapshot") as snapshot:
                with self.assertRaisesRegex(ValueError, "cannot be identified"):
                    installer.install(args)
                self.assertEqual(device.call_count, 1)
                snapshot.assert_not_called()

    def test_backup_failure_prevents_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(Path(tmp))
            with patch.object(installer, "verify_signed", return_value={}), \
                 patch.object(installer, "devicectl", return_value={"apps": [{"bundleIdentifier": args.bundle_id, "executableName": "TFM2Probe"}]}) as device, \
                 patch.object(installer, "snapshot", side_effect=ValueError("backup failed")):
                with self.assertRaisesRegex(ValueError, "backup failed"):
                    installer.install(args)
                self.assertEqual(device.call_count, 1)

    def test_changed_save_after_update_is_reported_and_original_hash_record_survives(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.args(Path(tmp))
            before = {"present": True, "sha256": {"save/slot": "original"}}
            after = {"present": True, "sha256": {"save/slot": "changed"}}
            with patch.object(installer, "verify_signed", return_value={"bundle_id": args.bundle_id}), \
                 patch.object(installer, "devicectl", side_effect=[
                     {"apps": [{"bundleIdentifier": args.bundle_id, "executableName": "TFM2Probe"}]},
                     {"installedApplications": [{"bundleID": args.bundle_id}]}]) as device, \
                 patch.object(installer, "snapshot", side_effect=[before, after]):
                with self.assertRaisesRegex(ValueError, "save files differ"):
                    installer.install(args)
                self.assertEqual(json.loads((args.backup / "changed-files.json").read_text()), ["save/slot"])
                self.assertEqual(before["sha256"]["save/slot"], "original")
                calls = [call.args[0] for call in device.call_args_list]
                self.assertEqual(calls[1][:3], ["device", "install", "app"])
                self.assertFalse(any("uninstall" in command or "launch" in command for command in calls))

    def test_previous_receipt_must_match_device_bundle_and_team(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = self.args(root)
            args.previous_install = root / "install.json"
            args.previous_install.write_text(json.dumps({"info": {"outcome": "success"}, "result": {
                "deviceIdentifier": "CONNECTION-ID", "installedApplications": [{"bundleID": args.bundle_id}]}}))
            (root / "signing-check.json").write_text(json.dumps({"bundle_id": args.bundle_id, "team": args.team}))
            self.assertEqual(installer.known_existing_app({}, args, "CONNECTION-ID"), "game")
            with self.assertRaises(ValueError):
                installer.known_existing_app({}, args, "OTHER-DEVICE")
            args.team = "OTHERTEAM1"
            with self.assertRaises(ValueError):
                installer.known_existing_app({}, args, "CONNECTION-ID")


if __name__ == "__main__":
    unittest.main()
