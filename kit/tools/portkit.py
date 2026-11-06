#!/usr/bin/env python3
"""Pinned input intake, local Steam update detection, and metadata-only staging.

This does not implement macOS APIs, run a game, sign in, or download updates.
An intake profile records observed files; it is NOT a compatibility approval.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_COMMIT = "c0f7cbdc69d8b1dca87a73a94490c3a65405762f"
ADAPTER_SHA256 = "66b29b82adf8c8b152176e3434f0d370c68592360ff567db934771ffeff1ad0c"
APP_ID = "3009300"


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_files(app):
    app = Path(app).resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.teamsamoyed.teamfightmanager2":
        raise ValueError("Not the Teamfight Manager 2 Mac bundle")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable:
        raise ValueError("Invalid bundle executable name")
    paths = {"game": app / "Contents/MacOS" / executable,
             "steam_sdk": app / "Contents/MacOS/libsteam_api.dylib",
             "data": app / "Contents/MacOS/bundle.game_data"}
    for path in paths.values():
        path.resolve(strict=True).relative_to(app)
    return info, paths


def observe(app):
    info, paths = source_files(app)
    # Select only non-account fields. Never serialize LastOwner or login state.
    manifest = Path(app).resolve().parents[2] / "appmanifest_3009300.acf"
    build_id = None
    if manifest.is_file():
        text = manifest.read_text()
        app_id = re.search(r'"appid"\s+"(\d+)"', text)
        build = re.search(r'"buildid"\s+"(\d+)"', text)
        if not app_id or app_id[1] != APP_ID:
            raise ValueError("Unexpected Steam app manifest identity")
        build_id = build[1] if build else None
    return {"schema": 1, "app_id": APP_ID,
            "status": "observed-inputs-only-not-gameplay-validated",
            "bundle_version": info.get("CFBundleShortVersionString"),
            "steam_build_id": build_id,
            "files": {role: {"relative_path": str(path.relative_to(app)),
                             "size": path.stat().st_size, "sha256": sha256(path)}
                      for role, path in paths.items()},
            "upstream": {"repository": "https://github.com/chrissotraidis/agepad",
                         "commit": UPSTREAM_COMMIT, "adapter_sha256": ADAPTER_SHA256}}


def differences(pinned, current):
    changes = []
    for key in ("schema", "app_id", "bundle_version", "steam_build_id", "upstream"):
        if pinned.get(key) != current.get(key):
            changes.append(key)
    for role in sorted(set(pinned.get("files", {})) | set(current.get("files", {}))):
        if pinned.get("files", {}).get(role) != current.get("files", {}).get(role):
            changes.append("files." + role)
    return changes


def write_new(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def require_outside_source(destination, app):
    destination, app = Path(destination).resolve(), Path(app).resolve()
    if destination == app or app in destination.parents:
        raise ValueError("Outputs must be outside the Steam source bundle")


def prepare(app, profile, output):
    output = Path(output).resolve()
    app = Path(app).resolve()
    require_outside_source(output, app)
    current = observe(app)
    changes = differences(profile, current)
    if changes:
        raise ValueError("Source changed; re-audit before staging: " + ", ".join(changes))
    adapter_path = ROOT / "vendor/agepad/prepare-de-load-image.py"
    if sha256(adapter_path) != ADAPTER_SHA256:
        raise ValueError("Vendored AgePad adapter does not match recorded digest")
    if output.exists():
        raise ValueError("Use a fresh output directory; existing stages are preserved")
    output.mkdir(parents=True)
    (output / "INCOMPLETE").write_text("Staging incomplete. Do not use.\n")
    spec = importlib.util.spec_from_file_location("agepad_adapter", adapter_path)
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
    _, files = source_files(app)
    reports = {}
    with tempfile.TemporaryDirectory(prefix="tfm2-thin-", dir=output) as temporary:
        for role, name in (("game", "TeamfightManager2.dylib"),
                           ("steam_sdk", "libsteam_api.dylib")):
            thin = Path(temporary) / name
            arches = subprocess.check_output(["lipo", "-archs", str(files[role])], text=True).split()
            if "arm64" not in arches:
                raise ValueError("No ARM64 slice in " + role)
            if len(arches) > 1:
                subprocess.run(["lipo", str(files[role]), "-thin", "arm64", "-output", str(thin)], check=True)
            else:
                thin.write_bytes(files[role].read_bytes())
            reports[role] = adapter.prepare(thin, output / name, platform="ios-device")
            # Temporary paths are not persistent input identities.
            reports[role]["source"] = current["files"][role]["relative_path"] + " (arm64 slice)"
    if differences(current, observe(app)):
        raise ValueError("Steam source changed during staging; stage remains INCOMPLETE")
    report = {"schema": 1, "status": "metadata-only-not-loadable-game",
              "claim": "Original sections preserved. macOS API implementation and signed device game execution remain unverified.",
              "input_profile": current, "images": reports,
              "not_included": ["game data", "Steam client", "macOS compatibility libraries", "provisioning", "gameplay validation"]}
    write_new(output / "stage-report.json", report)
    (output / "INCOMPLETE").unlink()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["record-inputs", "check-updates", "prepare-images"])
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "record-inputs":
            require_outside_source(args.profile, args.app)
            write_new(args.profile, observe(args.app.resolve()))
            print("Recorded input hashes; this is not a compatibility approval.")
        elif args.command == "check-updates":
            profile = json.loads(args.profile.read_text())
            changes = differences(profile, observe(args.app.resolve()))
            print(json.dumps({"local_source_changed": bool(changes), "changed": changes,
                              "scope": "installed Mac Steam copy only; not Steam server latest-version query",
                              "action": "re-audit and rebuild before deployment" if changes else "inputs match; gameplay still unverified"}, indent=2))
            return 2 if changes else 0
        else:
            if not args.output:
                parser.error("prepare-images requires --output")
            prepare(args.app, json.loads(args.profile.read_text()), args.output)
            print("Prepared metadata-only diagnostic images. Not a playable port or installable IPA.")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
