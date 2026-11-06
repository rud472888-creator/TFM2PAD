#!/usr/bin/env python3
"""Privately stage pinned user binaries with explicit load-only dependency shims.

Never packages assets, enters main, logs in, signs, or claims gameplay success.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import portkit
import build_gl4es


def image_plan(mapping, steam_init_bridge=False, steam_sdk_client_order_fix=False):
    """Exact output names/dependency edits; the default legacy SDK stays intact."""
    result = []
    for role, name in (("game", "TeamfightManager2.dylib"), ("steam_sdk", "libsteam_api.dylib")):
        role_mapping = dict(mapping)
        if steam_init_bridge:
            import steam_init_bridge_build as bridge
            replacement = bridge.WRAPPER_ID if role == "game" else bridge.ORIGINAL_ID
            role_mapping.update({"@loader_path/libsteam_api.dylib": replacement, "@rpath/libsteam_api.dylib": replacement})
            if role == "steam_sdk": name = bridge.ORIGINAL_FILE
        if role == "steam_sdk" and steam_sdk_client_order_fix:
            import steam_sdk_client_build as client_boundary
            role_mapping["/usr/lib/libSystem.B.dylib"] = client_boundary.INSTALL_NAME
        result.append((role, name, role_mapping))
    return result


def validate_gl4es_build(directory):
    """Inspect a completed build without loading or executing its code."""
    directory = Path(directory).resolve(strict=True)
    report_path = directory / "build-report.json"
    if (directory / "INCOMPLETE").exists():
        raise ValueError("GL4ES build is marked incomplete")
    report = json.loads(report_path.read_text())
    if report.get("schema_version") != 1 or report.get("status") != "compiled_not_device_validated":
        raise ValueError("GL4ES requires completed build-report schema1/status compiled_not_device_validated")
    if report.get("commit") != build_gl4es.COMMIT or report.get("upstream") != build_gl4es.UPSTREAM:
        raise ValueError("GL4ES build is not from the toolkit's pinned upstream commit")
    commands = report.get("commands")
    if not isinstance(commands, list) or not commands or any(command.get("exit_code") != 0 for command in commands):
        raise ValueError("GL4ES report contains missing or failed build commands")
    configure_no_ctor = any("-DNO_INIT_CONSTRUCTOR=ON" in command.get("argv", []) for command in commands)
    if not configure_no_ctor:
        raise ValueError("GL4ES build does not document disabled automatic initialization")
    entries = [item for item in report.get("artifacts", []) if item.get("file") == "TFMGL4ES.dylib"]
    if len(entries) != 1:
        raise ValueError("GL4ES report must contain exactly one TFMGL4ES.dylib artifact")
    artifact = entries[0]
    dylib = directory / "TFMGL4ES.dylib"
    if dylib.is_symlink() or not dylib.is_file():
        raise ValueError("GL4ES dylib must be a regular file in its build directory")
    digest = artifact.get("sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or portkit.sha256(dylib) != digest or dylib.stat().st_size != artifact.get("size"):
        raise ValueError("GL4ES dylib digest or size differs from its build report")
    env = dict(os.environ)
    architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(dylib)], env=env, text=True).split()
    if architectures != ["arm64"]:
        raise ValueError("GL4ES dylib must contain only the iOS ARM64 slice")
    loads = subprocess.check_output(["xcrun", "otool", "-arch", "arm64", "-l", str(dylib)], env=env, text=True)
    build_command = re.search(r"cmd LC_BUILD_VERSION\b(?:(?!Load command).)*", loads, re.S)
    if not build_command or not re.search(r"\bplatform (?:2|IOS)\b", build_command[0]):
        raise ValueError("GL4ES dylib is not marked for the iOS device platform")
    if re.search(r"\bcmd LC_ROUTINES(?:_64)?\b|\bsectname (?:__mod_init_func|__init_offsets)\b", loads):
        raise ValueError("GL4ES dylib contains an automatic initializer")
    # Check Mach-O section types as well as conventional section names.
    for section in re.split(r"(?m)^Section\s*$", loads)[1:]:
        flags = re.search(r"\bflags (0x[0-9a-fA-F]+)\b", section)
        if flags and int(flags[1], 16) & 0xff in (0x9, 0x16):
            raise ValueError("GL4ES dylib contains an initializer-pointer/offset section")
    install_names = subprocess.check_output(["xcrun", "otool", "-D", str(dylib)], env=env, text=True).splitlines()[1:]
    if install_names != ["@rpath/TFMGL4ES.dylib"]:
        raise ValueError("Unexpected GL4ES dylib install name")
    nm = subprocess.check_output(["xcrun", "nm", "-arch", "arm64", "-gU", str(dylib)], env=env, text=True)
    exports = {line.split()[-1] for line in nm.splitlines() if line.split() and not line.rstrip().endswith(":")}
    required = {"_gl4es_GetProcAddress", "_initialize_gl4es", "_close_gl4es", "_set_getprocaddress", "_set_getmainfbsize", "_gl4es_set_getprocaddress", "_gl4es_set_getmainfbsize"}
    if required - exports or required - set(report.get("required_exports_verified", [])):
        raise ValueError("GL4ES is missing required initialization/resolver/callback exports")
    provenance = {"build_report_schema_version": 1, "build_status": report["status"],
                  "build_report_sha256": portkit.sha256(report_path), "upstream": report["upstream"],
                  "commit": report["commit"], "upstream_version": report.get("upstream_version"),
                  "license": report.get("license"), "license_sha256": report.get("license_sha256"),
                  "output": "Frameworks/TFMGL4ES.dylib", "sha256": digest, "size": artifact["size"],
                  "architectures": architectures, "platform": "ios-device", "install_name": install_names[0],
                  "required_exports_verified": sorted(required), "constructors_disabled_verified": True,
                  "constructor_verification": "NO_INIT_CONSTRUCTOR=ON in successful configure command; actual dylib has no LC_ROUTINES, initializer-pointer, or initializer-offset section",
                  "limitations": report.get("limitations", []), "device_validation": "Not performed by staging"}
    return dylib, provenance


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--app", required=True, type=Path)
    p.add_argument("--profile", required=True, type=Path)
    p.add_argument("--boundaries", required=True, type=Path)
    p.add_argument("--probe-app", required=True, type=Path)
    p.add_argument("--gl4es-build", type=Path, help="Optional completed pinned GL4ES build directory")
    p.add_argument("--steam-init-bridge", action="store_true", help="Opt in to sole Init override plus uniquely named section-preserved original SDK; no SDK execution")
    p.add_argument("--steam-sdk-client-order-fix", action="store_true", help="Opt in to SDK-only client ABI boundary; changes only SDK libSystem dependency metadata")
    args = p.parse_args()
    source, target = args.app.resolve(), args.probe_app.resolve()
    portkit.require_outside_source(target, source)
    profile = json.loads(args.profile.read_text())
    current = portkit.observe(source)
    if portkit.differences(profile, current):
        p.error("Original inputs or adapter changed; audit and record new input profile first")
    if plistlib.loads((target / "Info.plist").read_bytes()).get("CFBundleIdentifier") != "org.tfm2pad.staging":
        p.error("Target must be the diagnostic probe bundle")
    build = json.loads((args.boundaries / "build-report.json").read_text())
    if build.get("status") != "built_load_only_boundaries" or (args.boundaries / "INCOMPLETE").exists():
        p.error("A complete load-only boundary build is required")
    if build["survey_source"]["sha256"] != current["files"]["game"]["sha256"]:
        p.error("Boundary survey is from another game version")
    frameworks = target / "Frameworks"
    if frameworks.exists():
        p.error("Probe already has Frameworks; use a fresh probe build for new staging")
    mapping = json.loads((args.boundaries / "dependency-map.json").read_text())
    reserved = {"TeamfightManager2.dylib", "libsteam_api.dylib", "TFMOriginalSteamAPI.dylib", "TFMSteamSDKClientBoundary.dylib"}
    for item in build["boundaries"]:
        name = item["file"]
        if Path(name).name != name or not name.endswith(".dylib"):
            p.error("Invalid boundary filename")
        if name in reserved:
            p.error("Boundary artifact collides with a game/SDK staging filename")
        if portkit.sha256(args.boundaries / name) != item["sha256"]:
            p.error("Boundary library changed since build")
    gl4es_source, gl4es_provenance = None, None
    if args.gl4es_build:
        if any(item["file"] == "TFMGL4ES.dylib" for item in build["boundaries"]):
            p.error("GL4ES filename collides with a boundary artifact")
        try:
            gl4es_source, gl4es_provenance = validate_gl4es_build(args.gl4es_build)
        except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
            p.error(str(error))
    if build.get("graphics_runtime_enabled") and not gl4es_source:
        p.error("Graphics runtime boundaries require --gl4es-build")
    adapter_path = portkit.ROOT / "vendor/agepad/prepare-de-load-image.py"
    if portkit.sha256(adapter_path) != portkit.ADAPTER_SHA256:
        p.error("Adapter digest mismatch")
    spec = importlib.util.spec_from_file_location("adapter", adapter_path)
    adapter = importlib.util.module_from_spec(spec); spec.loader.exec_module(adapter)
    _, files = portkit.source_files(source)
    bridge, bridge_pin, bridge_sources = None, None, None
    if args.steam_init_bridge:
        import steam_init_bridge_build as bridge
        if not build.get("steam_ipc_runtime_enabled") or not build.get("shared_steam_ipc"):
            p.error("Steam init bridge requires the complete shared Steam IPC game boundary mode")
        import steam_ipc_build
        steam_ipc_build.validate(args.boundaries, build["shared_steam_ipc"])
        if "_TFMSteamIPCPrepareForGame" not in build["shared_steam_ipc"].get("all_direct_exports", []):
            p.error("Steam init bridge needs newly built shared IPC with PrepareForGame, not an older standalone SDK probe package")
        bridge_pin = bridge.inspect_input_sdk(files["steam_sdk"], current["files"]["steam_sdk"])
        bridge_sources = bridge.source_hashes()
    client_boundary, client_inputs = None, None
    if args.steam_sdk_client_order_fix:
        import steam_sdk_client_build as client_boundary
        import steam_init_bridge_build as sdk_pins
        client_inputs = {"source_hashes": client_boundary.source_hashes(),
                         "common_runtime": client_boundary.common_input(args.boundaries, build),
                         "original_sdk_input": sdk_pins.inspect_input_sdk(files["steam_sdk"], current["files"]["steam_sdk"]),
                         "original_game_input": client_boundary.game_input(files["game"], current["files"]["game"])}
    frameworks.mkdir()
    marker = target / "LoaderStageIncomplete"
    marker.write_text("Do not sign or launch until staging completes.\n")
    if build.get("graphics_runtime_enabled"):
        resources = target / "TFMOpenGLResources.bundle"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.tfm2pad.opengl-resources",
            "CFBundleName": "TFM OpenGL Adapter Resources", "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1", "CFBundleInfoDictionaryVersion": "6.0"}))
    for item in build["boundaries"]:
        shutil.copy2(args.boundaries / item["file"], frameworks / item["file"])
    if gl4es_source:
        staged_gl4es = frameworks / "TFMGL4ES.dylib"
        shutil.copy2(gl4es_source, staged_gl4es)
        if portkit.sha256(staged_gl4es) != gl4es_provenance["sha256"]:
            p.error("GL4ES changed during copy; incomplete marker retained")
    images = {}
    client_report = None
    if client_boundary:
        client_report = client_boundary.build(frameworks, client_inputs["common_runtime"])
        if client_report["source_hashes"] != client_inputs["source_hashes"]:
            p.error("SDK-only provider sources changed during staging")
    with tempfile.TemporaryDirectory(prefix="tfm2-loader-", dir=target.parent) as temp:
        for role, name, role_mapping in image_plan(mapping, args.steam_init_bridge, args.steam_sdk_client_order_fix):
            thin = Path(temp) / name
            subprocess.run(["lipo", str(files[role]), "-thin", "arm64", "-output", str(thin)], check=True)
            images[role] = adapter.prepare(thin, frameworks / name, platform="ios-device", dependency_map=role_mapping)
            images[role]["source"] = current["files"][role]["relative_path"] + " (arm64 slice)"
            images[role]["output"] = "Frameworks/" + name
    bridge_report = None
    if bridge:
        if bridge.source_hashes() != bridge_sources:
            p.error("Steam init bridge sources changed during staging")
        if bridge.WRAPPER_ID not in bridge.metadata((frameworks / "TeamfightManager2.dylib").read_bytes())["loads"]:
            p.error("Staged game does not import the expected SDK wrapper")
        bridge_report = bridge.build(frameworks, bridge_pin)
        if bridge_report["source_hashes"] != bridge_sources:
            p.error("Steam init bridge sources changed during wrapper build")
    if client_boundary:
        client_report = client_boundary.finish(frameworks, client_report, client_inputs["original_sdk_input"],
                                               client_inputs["original_game_input"], args.steam_init_bridge)
        client_boundary.validate(frameworks, client_report, client_inputs, args.steam_init_bridge)
    if portkit.differences(current, portkit.observe(source)):
        p.error("Original source changed during staging; incomplete marker retained")
    report = {"status": "staged_for_load_only_probe", "game_main_called": False,
              "original_inputs": current, "images": images, "dependency_map": mapping,
              "boundary_build_sha256": portkit.sha256(args.boundaries / "build-report.json"),
              "steam_init_bridge_enabled": args.steam_init_bridge,
              "steam_sdk_client_order_fix_enabled": args.steam_sdk_client_order_fix,
              "limitations": ["Many boundaries abort when called", "No assets or Steam client included", "No gameplay or authentication validation"]}
    if gl4es_provenance:
        report["gl4es"] = gl4es_provenance
    if bridge_report:
        report["steam_init_bridge"] = bridge_report
    if client_report:
        report["steam_sdk_client_order_fix"] = client_report
    (target / "loader-stage.json").write_text(json.dumps(report, indent=2) + "\n")
    marker.unlink()
    print("Staged personal game/SDK images for load-only probe. Keep bundle private; sign before device use.")


if __name__ == "__main__":
    main()
