"""Signing boundary tests. Never access Apple accounts, a Keychain, or a device."""
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "kit/tools"))
import sign_probe

TEAM = "ABCDE12345"
BUNDLE = "org.example.owner.tfm2pad"
PREFIX = "OLDPREFIX1"


def profile():
    return {"TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [PREFIX],
        "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=1), "ProvisionedDevices": ["TEST-UDID"],
        "DeveloperCertificates": [b"test-certificate"], "Entitlements": {
            "application-identifier": PREFIX + ".*", "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": True, "keychain-access-groups": [PREFIX + ".*"]}}


class SigningPolicyTests(unittest.TestCase):
    def entitlements(self, value, **kwargs):
        return sign_probe.signing_entitlements(value, bundle_id=BUNDLE, team=TEAM, **kwargs)

    def test_owner_id_and_old_app_prefix_are_distinct_from_team(self):
        value = profile()
        before = plistlib.dumps(value)
        result = self.entitlements(value, online_launch=True)
        self.assertEqual(result["application-identifier"], PREFIX + "." + BUNDLE)
        self.assertEqual(result["keychain-access-groups"], [PREFIX + "." + BUNDLE])
        self.assertEqual(plistlib.dumps(value), before)

    def test_refuses_wrong_app_team_keychain_and_expired_or_unprovisioned_device(self):
        for key, changed in (("application-identifier", PREFIX + ".org.other.app"),
                             ("com.apple.developer.team-identifier", "OTHERTEAM1"),
                             ("keychain-access-groups", ["OTHER.*"])):
            value = profile()
            value["Entitlements"][key] = changed
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.entitlements(value, online_launch=True)
        value = profile()
        value["ExpirationDate"] = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(seconds=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            sign_probe.validate_profile(value, bundle_id=BUNDLE, team=TEAM, device="TEST-UDID")
        with self.assertRaisesRegex(ValueError, "UDID"):
            sign_probe.validate_profile(profile(), bundle_id=BUNDLE, team=TEAM, device="OTHER-UDID")

    def test_no_private_keychain_group_for_default_diagnostic(self):
        self.assertNotIn("keychain-access-groups", self.entitlements(profile()))

    def test_template_and_malformed_ids_are_refused(self):
        for value in (sign_probe.STAGING_BUNDLE_ID, "a.*", "a", "a.b\nCODE_SIGNING_ALLOWED=NO", "a/b.c"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                sign_probe.validate_bundle_id(value)

    def test_identity_requires_local_private_key_and_profile_membership(self):
        digest = hashlib.sha1(b"test-certificate").hexdigest().upper()
        with patch.object(sign_probe.subprocess, "check_output", return_value=f'1) {digest} "Apple Development"'):
            self.assertEqual(sign_probe.select_identity(profile()), digest)
            with self.assertRaises(ValueError):
                sign_probe.select_identity(profile(), "0" * 40)
        with patch.object(sign_probe.subprocess, "check_output", return_value="0 valid identities found"):
            with self.assertRaises(ValueError):
                sign_probe.select_identity(profile())

    def test_codesign_failure_preserves_source_and_publishes_no_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "unsigned.app"
            source.mkdir()
            info = {"CFBundleIdentifier": sign_probe.STAGING_BUNDLE_ID, "CFBundleExecutable": "TFM2Probe"}
            original = plistlib.dumps(info)
            (source / "Info.plist").write_bytes(original)
            (source / "TFM2Probe").write_bytes(b"unsigned binary")
            output = Path(tmp) / "signed.app"
            profile_path = Path(tmp) / "profile.mobileprovision"
            profile_path.write_bytes(b"profile fixture")
            with patch.object(sign_probe, "read_profile", return_value=profile()), \
                 patch.object(sign_probe, "select_identity", return_value="TEST"), \
                 patch.object(sign_probe.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "codesign")):
                with self.assertRaises(subprocess.CalledProcessError):
                    sign_probe.sign_copy(source, output, profile_path=profile_path, bundle_id=BUNDLE, team=TEAM, device="TEST-UDID")
            self.assertEqual((source / "Info.plist").read_bytes(), original)
            self.assertEqual((source / "TFM2Probe").read_bytes(), b"unsigned binary")
            self.assertFalse((source / "embedded.mobileprovision").exists())
            self.assertFalse(output.exists())
            self.assertEqual(list(Path(tmp).glob(".tfm2-sign-*")), [])

    def test_partial_source_and_external_links_fail_before_any_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "unsigned.app"
            source.mkdir()
            (source / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": sign_probe.STAGING_BUNDLE_ID, "CFBundleExecutable": "TFM2Probe"}))
            marker = source / "AssetStageIncomplete"
            marker.touch()
            with patch.object(sign_probe, "read_profile") as read:
                with self.assertRaisesRegex(ValueError, "incomplete"):
                    sign_probe.sign_copy(source, Path(tmp) / "output.app", profile_path=Path(tmp) / "none", bundle_id=BUNDLE, team=TEAM, device="TEST-UDID")
                read.assert_not_called()
            marker.unlink()
            (source / "outside").symlink_to(Path(tmp) / "private")
            with self.assertRaisesRegex(ValueError, "symlink"):
                sign_probe.sign_copy(source, Path(tmp) / "output.app", profile_path=Path(tmp) / "none", bundle_id=BUNDLE, team=TEAM, device="TEST-UDID")


if __name__ == "__main__":
    unittest.main()
