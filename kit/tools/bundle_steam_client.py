#!/usr/bin/env python3
"""Copy a validated private Steam load-diagnostic set into this toolkit's probe.

Copies eight binary images plus their separately built runtime boundaries.
Never overwrites game frameworks, signs, installs, loads Steam, or logs in.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import portkit
import stage_steam_client as staging
import steam_ipc_build

BUNDLE_ID = "org.tfm2pad.staging"


def validate_client_stage(directory, profile_path):
    directory = Path(directory).resolve(strict=True)
    profile_path = Path(profile_path).resolve(strict=True)
    profile = json.loads(profile_path.read_text())
    pins = {item["path"]: item for item in profile["installed_client"]["images"]}
    if set(pins) != set(staging.ALLOWLIST):
        raise ValueError("Profile must contain exactly the eight reviewed binary paths")
    report_path = directory / "steam-client-stage.json"
    report = json.loads(report_path.read_text())
    if (directory / "INCOMPLETE").exists() or report.get("schema_version") != 1 or report.get("status") != "staged_ios_client_requires_runtime_boundaries":
        raise ValueError("A complete isolated Steam client stage is required")
    if not report.get("vendor_sections_preserved") or not report.get("source_hashes_verified_before_and_after") or report.get("profile_sha256") != portkit.sha256(profile_path):
        raise ValueError("Steam stage profile/section/source verification is incomplete")
    images = report.get("images", [])
    if len(images) != len(staging.ALLOWLIST) or {item["source_relative"] for item in images} != set(staging.ALLOWLIST):
        raise ValueError("Steam stage contains an unexpected image set")
    files = []
    names = set()
    for item in images:
        source_relative = item["source_relative"]
        pin = pins[source_relative]
        if item["original_sha256"] != pin["sha256"] or item["arm64_sha256"] != pin["arm64_sha256"] or item.get("instructions_changed") is not False or item.get("platform") != "IOS":
            raise ValueError("Steam staged image identity/platform mismatch: " + source_relative)
        relative = Path(item["output"])
        if len(relative.parts) != 2 or relative.parts[0] != "Frameworks" or not relative.name.endswith(".dylib") or relative.name in names:
            raise ValueError("Invalid or duplicate staged image output")
        names.add(relative.name)
        path = directory / relative
        if path.is_symlink() or not path.is_file() or portkit.sha256(path) != item["output_sha256"] or path.stat().st_size != item["output_size"]:
            raise ValueError("Staged Steam image changed: " + relative.name)
        if staging.sections(path.read_bytes()) != item["original_sections"]:
            raise ValueError("Staged vendor sections changed: " + relative.name)
        files.append({"source": path, "file": relative.name, "sha256": item["output_sha256"], "size": item["output_size"], "role": "client_image", "source_relative": source_relative})
    if not report.get("boundary_package"):
        raise ValueError("Stage client images with --boundaries before bundling")
    return report, pins, files


def bundle(args):
    target = args.probe_app.resolve(strict=True)
    info = plistlib.loads((target / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundlePackageType") != "APPL":
        raise ValueError("Target must be this toolkit's private diagnostic app bundle")
    if target == portkit.ROOT or portkit.ROOT in target.parents:
        raise ValueError("Private Steam binaries cannot be bundled into deliverable outputs")
    marker = target / "SteamStageIncomplete"
    destination_report = target / "steam-stage.json"
    if marker.exists() or destination_report.exists():
        raise ValueError("Probe already has Steam staging metadata; use a fresh probe bundle")
    if (target / "LoaderStageIncomplete").exists():
        raise ValueError("Existing game loader staging is incomplete")
    frameworks = target / "Frameworks"
    if frameworks.is_symlink() or not frameworks.is_dir():
        raise ValueError("Existing diagnostic game Frameworks directory is required")
    stage_dir = args.client_stage.resolve(strict=True)
    boundary_dir = args.boundaries.resolve(strict=True)
    stage, pins, files = validate_client_stage(stage_dir, args.profile)
    _, boundaries = staging.validate_steam_boundaries(boundary_dir, staging.profile_identities(pins))
    if stage["boundary_package"] != boundaries:
        raise ValueError("Steam stage was remapped against a different boundary package")
    existing = boundaries["required_existing_game_libraries"]
    for item in existing:
        path = frameworks / item["file"]
        if path.is_symlink() or not path.is_file() or portkit.sha256(path) != item["sha256"]:
            raise ValueError("Existing game boundary dependency differs from the Steam build: " + item["file"])
    for item in boundaries["libraries"]:
        path = boundary_dir / item["file"]
        files.append({"source": path, "file": item["file"], "sha256": item["sha256"], "size": path.stat().st_size, "role": "steam_boundary"})
    ipc = boundaries.get("shared_steam_ipc")
    ipc_profile_destination = target / steam_ipc_build.PROFILE
    if ipc:
        # The game loader stage already copied the one shared IPC dylib.
        # Require its exact identity; do not add another copy or overwrite it.
        steam_ipc_build.validate(boundary_dir, ipc)
        if sum(item["file"] == steam_ipc_build.FILE for item in existing) != 1 or any(item["file"] == steam_ipc_build.FILE for item in files):
            raise ValueError("Shared IPC must occur exactly once as an existing game library")
        if ipc_profile_destination.exists() or ipc_profile_destination.is_symlink():
            raise ValueError("Refusing to overwrite an existing Steam IPC profile")
    if len({item["file"] for item in files}) != len(files):
        raise ValueError("Client and boundary filenames collide")
    for item in files:
        destination = frameworks / item["file"]
        if destination.exists() or destination.is_symlink():
            raise ValueError("Refusing to overwrite an existing framework: " + item["file"])
    marker.write_text("Steam staging incomplete; do not sign or launch.\n")
    report = {"schema_version": 1, "status": "incomplete", "bundle_identifier": BUNDLE_ID,
              "source_stage_sha256": portkit.sha256(stage_dir / "steam-client-stage.json"),
              "profile_sha256": portkit.sha256(args.profile), "boundary_package": boundaries,
              "existing_game_libraries_unchanged": existing, "files": [], "client_loaded": False,
              "client_executed": False, "ipc_started": False, "login_performed": False,
              "account_or_configuration_files_copied": False, "signing_or_installation_performed": False,
              "limitations": ["Bundled for an optional load-only diagnostic; no Steam initialization or sign-in result is claimed.",
                              "Unknown boundary functions/selectors still exit78; constructors and client ABI behavior remain unverified."]}
    try:
        for item in files:
            destination = frameworks / item["file"]
            shutil.copy2(item["source"], destination)
            if portkit.sha256(destination) != item["sha256"] or destination.stat().st_size != item["size"]:
                raise ValueError("Steam copy verification failed: " + item["file"])
            record = {key: value for key, value in item.items() if key != "source"}
            record["output"] = "Frameworks/" + item["file"]
            report["files"].append(record)
        if ipc:
            source_profile = boundary_dir / steam_ipc_build.PROFILE
            shutil.copy2(source_profile, ipc_profile_destination)
            if portkit.sha256(ipc_profile_destination) != ipc["profile_sha256"]:
                raise ValueError("Shared Steam IPC profile changed during copy")
            report["shared_steam_ipc"] = dict(ipc, library_copy_policy="reuse_exact_existing_game_image_once",
                profile_output=steam_ipc_build.PROFILE)
        # Recheck copied inputs and the untouched existing game dependencies.
        after_stage, _, _ = validate_client_stage(stage_dir, args.profile)
        _, after_boundaries = staging.validate_steam_boundaries(boundary_dir, staging.profile_identities(pins))
        if stage != after_stage or boundaries != after_boundaries:
            raise ValueError("Steam staging inputs changed during bundle copy")
        for item in existing:
            if portkit.sha256(frameworks / item["file"]) != item["sha256"]:
                raise ValueError("Existing game dependency changed during Steam staging: " + item["file"])
        if ipc and portkit.sha256(ipc_profile_destination) != ipc["profile_sha256"]:
            raise ValueError("Shared Steam IPC profile changed during bundle validation")
        report["status"] = "staged_for_optional_steam_client_load_not_executed"
        report["boundary_package"] = dict(boundaries, boundary_libraries_copied_into_this_stage=True)
        staging.write_report(destination_report, report)
        marker.unlink()
    except Exception as error:
        report["error_type"] = type(error).__name__
        staging.write_report(destination_report, report)
        raise
    print(json.dumps({"status": report["status"], "copied_files": len(files), "client_images": len(stage["images"]), "steam_boundaries": len(boundaries["libraries"]), "client_executed": False, "login_performed": False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-stage", required=True, type=Path)
    parser.add_argument("--boundaries", required=True, type=Path)
    parser.add_argument("--probe-app", required=True, type=Path)
    parser.add_argument("--profile", type=Path, default=portkit.ROOT / "evidence/steam-engine-feasibility.json")
    args = parser.parse_args()
    try:
        bundle(args)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
