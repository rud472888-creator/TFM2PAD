#!/usr/bin/env python3
"""Sign a fresh copy of the staging app with the owner's bundle ID and profile.

No account changes, installation, or changes to the source .app are performed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

STAGING_BUNDLE_ID = "org.tfm2pad.staging"
INCOMPLETE = ("ProbeBuildIncomplete", "LoaderStageIncomplete", "AssetStageIncomplete", "SteamStageIncomplete")


def validate_bundle_id(value):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value) or value == STAGING_BUNDLE_ID:
        raise ValueError("Use your own reverse-domain bundle ID (letters, numbers, periods, hyphens); the staging ID cannot be installed")
    return value


def read_profile(path):
    return plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)]))


def signing_entitlements(profile, *, bundle_id, team, online_launch=False):
    validate_bundle_id(bundle_id)
    entitlements = dict(profile["Entitlements"])
    if profile.get("TeamIdentifier") != [team] or entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Provisioning profile does not belong to the requested Apple team")
    prefix = profile["ApplicationIdentifierPrefix"][0]
    identifier = prefix + "." + bundle_id

    def authorizes(value):
        return isinstance(value, str) and (identifier == value or
            (value.endswith(".*") and identifier.startswith(value[:-1])))

    if not authorizes(entitlements.get("application-identifier")):
        raise ValueError("Provisioning profile does not authorize your bundle ID")
    entitlements["application-identifier"] = identifier
    groups = entitlements.pop("keychain-access-groups", [])
    if online_launch:
        if not isinstance(groups, list) or not any(authorizes(group) for group in groups):
            raise ValueError("Provisioning profile does not authorize this app's private Keychain access group")
        entitlements["keychain-access-groups"] = [identifier]
    return entitlements


def validate_profile(profile, *, bundle_id, team, device, online_launch=False):
    expiration = profile["ExpirationDate"]
    if expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("Provisioning profile has expired; rebuild the signing helper in Xcode")
    if device not in profile.get("ProvisionedDevices", []):
        raise ValueError("Target device UDID is not included in the provisioning profile")
    return signing_entitlements(profile, bundle_id=bundle_id, team=team, online_launch=online_launch)


def select_identity(profile, requested=None):
    allowed = {hashlib.sha1(value).hexdigest().upper() for value in profile.get("DeveloperCertificates", [])}
    available = set(re.findall(r"\b[0-9A-Fa-f]{40}\b", subprocess.check_output(
        ["security", "find-identity", "-v", "-p", "codesigning"], text=True)))
    matches = allowed & {value.upper() for value in available}
    if requested:
        if requested.upper() not in matches:
            raise ValueError("Requested signing certificate is absent from the profile or has no valid private key in Keychain")
        return requested.upper()
    if len(matches) != 1:
        raise ValueError("Expected one local signing identity matching the profile; pass --identity SHA1 to select one, or create the certificate in Xcode")
    return matches.pop()


def verify_signed(app, *, bundle_id, team, device):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != bundle_id:
        raise ValueError("Signed app Info.plist has a different bundle ID")
    profile = read_profile(app / "embedded.mobileprovision")
    expected = validate_profile(profile, bundle_id=bundle_id, team=team, device=device,
        online_launch=info.get("TFMPersonalLaunchMode") == "steam-online")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    details = subprocess.run(["codesign", "-d", "--verbose=4", str(app)], check=True, capture_output=True, text=True)
    fields = dict(line.split("=", 1) for line in (details.stdout + details.stderr).splitlines() if "=" in line)
    if fields.get("Identifier") != bundle_id or fields.get("TeamIdentifier") != team:
        raise ValueError("Actual code signature has a different app identifier or Apple team")
    signed = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
    for key, value in expected.items():
        if signed.get(key) != value:
            raise ValueError(f"Actual signed entitlement differs from the selected profile: {key}")
    if signed.get("keychain-access-groups", []) != expected.get("keychain-access-groups", []):
        raise ValueError("Actual signature contains unexpected Keychain groups")
    # Check the leaf certificate, not merely the displayed Authority name.
    with tempfile.TemporaryDirectory(prefix="tfm2-cert-") as tmp:
        cert_prefix = str(Path(tmp) / "cert")
        subprocess.run(["codesign", "-d", "--extract-certificates=" + cert_prefix, str(app)], check=True, capture_output=True)
        leaf = hashlib.sha1(Path(cert_prefix + "0").read_bytes()).hexdigest().upper()
    allowed = {hashlib.sha1(value).hexdigest().upper() for value in profile.get("DeveloperCertificates", [])}
    if leaf not in allowed:
        raise ValueError("Actual signing certificate is not authorized by the embedded provisioning profile")
    return {"bundle_id": bundle_id, "team": team, "certificate_sha1": leaf,
            "profile_expires": profile["ExpirationDate"].isoformat() + "Z"}


def sign_copy(source, output, *, profile_path, bundle_id, team, device, identity=None):
    source = source.resolve(strict=True)
    output = output.absolute()
    if output.exists() or output.is_symlink() or output.suffix != ".app":
        raise ValueError("--output must be a new .app path; existing output is never replaced")
    if source == output.resolve() or source in output.resolve().parents:
        raise ValueError("Signed output must be outside the source app")
    if any(next(source.rglob(name), None) for name in INCOMPLETE):
        raise ValueError("Game image or asset staging is incomplete; refusing to sign")
    info = plistlib.loads((source / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != STAGING_BUNDLE_ID or info.get("CFBundleExecutable") != "TFM2Probe":
        raise ValueError("Only this kit's unsigned staging app can be signed")
    if info.get("TFMPersonalLaunchMode") not in (None, "steam-online"):
        raise ValueError("Unrecognized personal launch mode")
    for path in source.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(source):
            raise ValueError("Source app contains a symlink outside the app")
    profile = read_profile(profile_path)
    entitlements = validate_profile(profile, bundle_id=bundle_id, team=team, device=device,
        online_launch=info.get("TFMPersonalLaunchMode") == "steam-online")
    identity = select_identity(profile, identity)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tfm2-sign-", dir=output.parent) as tmp:
        staged = Path(tmp) / output.name
        shutil.copytree(source, staged, symlinks=True)
        info["CFBundleIdentifier"] = bundle_id
        (staged / "Info.plist").write_bytes(plistlib.dumps(info))
        path = Path(tmp) / "entitlements.plist"
        path.write_bytes(plistlib.dumps(entitlements))
        shutil.copyfile(profile_path, staged / "embedded.mobileprovision")
        for library in sorted((staged / "Frameworks").rglob("*.dylib")):
            subprocess.run(["codesign", "--force", "--sign", identity, str(library)], check=True)
        subprocess.run(["codesign", "--force", "--sign", identity, "--entitlements", str(path),
                        "--generate-entitlement-der", str(staged)], check=True)
        result = verify_signed(staged, bundle_id=bundle_id, team=team, device=device)
        if output.exists():
            raise ValueError("Output appeared during signing; refusing to replace it")
        staged.rename(output)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "output", "profile"):
        parser.add_argument("--" + name, required=True, type=Path)
    for name in ("bundle-id", "team", "device"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--identity", help="Certificate SHA-1; otherwise select the sole profile-matching local identity")
    args = parser.parse_args()
    try:
        result = sign_copy(args.app, args.output, profile_path=args.profile, bundle_id=args.bundle_id,
                           team=args.team, device=args.device, identity=args.identity)
    except (ValueError, KeyError, IndexError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Signing failed: {error}\nSource app was not changed. No app was installed.\n")
    print(f"Verified signed app: {args.output}\nProfile expires: {result['profile_expires']}\nNo app installed.")


if __name__ == "__main__":
    main()
