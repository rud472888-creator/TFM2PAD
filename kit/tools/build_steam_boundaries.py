#!/usr/bin/env python3
"""Build separate device-survey-driven Steam client load boundaries; never load Steam."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import shutil
import build_loader_boundaries as common
import steam_ipc_build

ROOT = Path(__file__).resolve().parents[1]
STEAM = ROOT / "compat/steam"
KNOWN = {
    "AppKit": {"_NSWorkspaceLaunchConfigurationArguments", "_NSWorkspaceLaunchConfigurationEnvironment", "_OBJC_CLASS_$_NSRunningApplication", "_OBJC_CLASS_$_NSScreen", "_OBJC_CLASS_$_NSWorkspace"},
    "ApplicationServices": {"_GetCurrentProcess", "_GetFrontProcess", "_GetProcessPID"},
    "CoreGraphics": {"_CGDisplayBitsPerPixel", "_CGDisplayCopyDisplayMode", "_CGDisplayModeGetRefreshRate", "_CGDisplayModeRelease", "_CGDisplayPixelsHigh", "_CGDisplayPixelsWide", "_CGDisplayScreenSize", "_CGEventCreate", "_CGEventCreateKeyboardEvent", "_CGEventCreateMouseEvent", "_CGEventGetLocation", "_CGEventKeyboardSetUnicodeString", "_CGEventPost", "_CGEventSourceButtonState", "_CGEventSourceKeyState", "_CGEventSourceSecondsSinceLastEventType", "_CGGetActiveDisplayList", "_CGMainDisplayID"},
    "CoreServices": {"_AEBuildAppleEvent", "_AESendMessage", "_FSCreateStringFromHFSUniStr", "_FSGetCatalogInfo", "_FSGetVolumeInfo", "_FSPathMakeRef", "_LSRegisterURL"},
    "DiskArbitration": {"_DADiskCopyDescription", "_DADiskCreateFromBSDName", "_DASessionCreate", "_kDADiskDescriptionMediaUUIDKey"},
    "IOBluetooth": {"_OBJC_CLASS_$_IOBluetoothDevice"},
    "libSystem": {"_syslog$DARWIN_EXTSN"}, "Carbon": set(), "Cocoa": set(), "OpenGL": set(),
}
INHERITED = {
    "AppKit": {"_OBJC_CLASS_$_NSScreen"},
    "CoreGraphics": {"_CGDisplayCopyDisplayMode", "_CGDisplayModeGetRefreshRate", "_CGDisplayModeRelease", "_CGDisplayPixelsHigh", "_CGDisplayPixelsWide", "_CGGetActiveDisplayList", "_CGMainDisplayID"},
}
DIRECT = {name: set(values) for name, values in KNOWN.items()}
DIRECT["AppKit"] -= INHERITED["AppKit"]
DIRECT["CoreGraphics"] = {"_CGEventSourceSecondsSinceLastEventType"}
DIRECT["CoreServices"] = set()
SOURCES = {"AppKit": "ClientAppKit.m", "ApplicationServices": "ApplicationServices.m", "CoreGraphics": "CoreGraphics.m", "DiskArbitration": "DiskArbitration.m", "IOBluetooth": "IOBluetooth.m", "libSystem": "LibSystem.m"}
NAMES = {name: "TFMSteam" + ("LibSystem" if name == "libSystem" else name) + ".dylib" for name in KNOWN}
GAME_REEXPORT = {"AppKit": "TFMAppKit.dylib", "CoreGraphics": "TFMCoreGraphics.dylib", "OpenGL": "TFMOpenGL.dylib"}
DISPATCH_EXPORTS = {"_dispatch_source_create", "_dispatch_source_set_cancel_handler_f", "_TFMSteamDispatchCompatStatus"}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    text = json.dumps(value, indent=2) + "\n"
    if "/Users/" in text or "/home/" in text:
        raise ValueError("Metadata unexpectedly contains an absolute home path")
    path.write_text(text)


def build(args):
    survey_path = args.survey.resolve(strict=True)
    survey = json.loads(survey_path.read_text())
    client_dir = args.client_stage.resolve(strict=True)
    client = json.loads((client_dir / "steam-client-stage.json").read_text())
    game_dir = args.game_boundaries.resolve(strict=True)
    game_report = json.loads((game_dir / "build-report.json").read_text())
    if survey.get("status") != "complete" or not survey.get("device", {}).get("system_version"):
        raise ValueError("Need a completed actual-iPad Steam symbol survey")
    if client.get("status") != "staged_ios_client_requires_runtime_boundaries" or not client.get("vendor_sections_preserved") or (client_dir / "INCOMPLETE").exists():
        raise ValueError("Need a complete section-preserved isolated client stage")
    surveyed = {item["path"]: (item["sha256"], item["arm64_sha256"]) for item in survey["source"]["images"]}
    staged = {item["source_relative"]: (item["original_sha256"], item["arm64_sha256"]) for item in client["images"]}
    if surveyed != staged:
        raise ValueError("Client survey and staged binary set differ")
    if game_report.get("status") != "built_load_only_boundaries" or (game_dir / "INCOMPLETE").exists():
        raise ValueError("Need a complete existing game boundary build")
    game_records = {item["file"]: item for item in game_report["boundaries"]}
    ipc_record = game_report.get("shared_steam_ipc")
    dispatch_leases = bool(getattr(args, "dispatch_leases", False))
    dispatch_sources = {"compat/steam/" + name: sha(STEAM / name)
                        for name in ("SteamDispatchCompat.h", "SteamDispatchCompat.m")} if dispatch_leases else {}
    if dispatch_leases:
        if not ipc_record:
            raise ValueError("Dispatch leases require the explicit shared Steam runtime package")
        images = [item for item in client["images"] if item["source_relative"] == "MacOS/steamclient.dylib"]
        if len(images) != 1 or images[0]["arm64_sha256"] != "c608f74c74f6f90b794e47d51bce5421ef0f3dea0681faa8d10ce155c1a1cd09":
            raise ValueError("Dispatch leases require the exact audited native client")
        image = client_dir / images[0]["private_arm64"]
        if sha(image) != images[0]["arm64_sha256"]:
            raise ValueError("Pinned dispatch client input changed")
        # Both ordinary imports and a literal dynamic lookup spelling are
        # covered by this binary-string check. Computed lookups are not proven
        # absent: runtime adaptation is additionally restricted to exact code.
        if b"dispatch_source_get_handle\0" in image.read_bytes():
            raise ValueError("Audited client gained source_get_handle name usage")
    if bool(ipc_record) != bool(game_report.get("steam_ipc_runtime_enabled")):
        raise ValueError("Game shared IPC mode/report mismatch")
    if ipc_record:
        steam_ipc_build.validate(game_dir, ipc_record)
        system = game_records.get("TFMlibSystem.dylib")
        if not system or sha(game_dir / "TFMlibSystem.dylib") != system["sha256"]:
            raise ValueError("Shared IPC needs the exact existing game libSystem boundary")
        steam_ipc_build.validate_reexport_order(system.get("verified_reexports", []))
    for name in GAME_REEXPORT.values():
        if name not in game_records or sha(game_dir / name) != game_records[name]["sha256"]:
            raise ValueError("Existing game boundary missing or changed: " + name)
    raw_classes = {entry["name"]: entry["status"] for entry in survey["objc_classes"]}
    for name in ("NSWorkspace", "NSRunningApplication", "IOBluetoothDevice"):
        if raw_classes.get(name) != "missing":
            raise ValueError("Refusing duplicate/unknown native class: " + name)
    selected = []
    for library in survey["libraries"]:
        if not library["testable"]:
            continue
        missing = {entry["import"] for entry in library["symbols"] if entry["status"] == "missing"} - {"dyld_stub_binder"}
        # Native symbol lookup succeeds for sem*, but an actual iPad login
        # reaches forbidden semget syscall/SIGSYS. Explicit shared-IPC mode
        # routes those available names through the one app-local state image.
        semaphore_override = bool(ipc_record) and library["provider"] == "libSystem" and any(
            entry["import"] in steam_ipc_build.SEMAPHORE_EXPORTS for entry in library["symbols"])
        if missing or library["load_status"] == "missing" or semaphore_override:
            provider = library["provider"]
            if provider not in KNOWN or missing - KNOWN[provider]:
                raise ValueError("Unreviewed missing imports for " + provider)
            selected.append((provider, library, missing))
    selected.sort(key=lambda item: (item[0] != "AppKit", item[0]))
    output = args.output.resolve()
    if output.exists():
        raise ValueError("Use a fresh private output directory")
    if output == ROOT or ROOT in output.parents:
        raise ValueError("Compiled Steam boundaries belong in private work, outside deliverables")
    output.mkdir(parents=True)
    (output / "INCOMPLETE").write_text("Boundary build incomplete; do not load.\n")
    generated = output / "generated"; generated.mkdir()
    env = dict(os.environ)
    report = {"schema_version": 1, "status": "incomplete", "generated_at": datetime.now(timezone.utc).isoformat(),
              "survey_sha256": sha(survey_path), "client_stage_sha256": sha(client_dir / "steam-client-stage.json"),
              "survey_device": survey["device"], "source_binary_set": survey["source"],
              "game_boundary_build_sha256": sha(game_dir / "build-report.json"), "boundaries": [],
              "required_existing_game_libraries": [{"file": name, "sha256": game_records[name]["sha256"]} for name in GAME_REEXPORT.values()],
              "client_loaded": False, "client_executed": False, "login_performed": False, "identity_signing_or_installation": False,
              "excluded_loader_special_symbols": ["dyld_stub_binder"],
              "limitations": ["Names resolved for a future diagnostic load only; constructors/runtime behavior remain untested.",
                  "Unknown functions and selectors persist boundary-failure.json and exit78.",
                  "NSWorkspace/NSRunningApplication are app-scoped; global app enumeration returns nil (unavailable), not a fabricated system list.",
                  "DiskArbitration/Bluetooth nil means service unavailable, not a statement about hardware or ownership.",
                  "CGEventSourceSecondsSinceLastEventType adapts any-input queries to this app foreground activity, not global input idle time; other event types fail fast.",
                  "Presence observers last for process lifetime; keep boundary images loaded.",
                  "No sign-in, ownership, Steam initialization or game-success answers are synthesized."], "commands": []}
    report["dispatch_descriptor_leases_enabled"] = dispatch_leases
    if dispatch_leases:
        report["dispatch_descriptor_leases"] = {
            "provider": "TFMSteamLibSystem.dylib", "source_hashes": dispatch_sources,
            "client_arm64_sha256": images[0]["arm64_sha256"],
            "native_create_return_offsets": [0x10c14b0, 0x10c14cc],
            "native_cancel_setter_return_offsets": [0x10c156c, 0x10c157c],
            "native_event_callback_offset": 0x10c168c,
            "native_cancel_callback_offsets": [0x10c2cc8, 0x10c2ce8],
            "exports": sorted(DISPATCH_EXPORTS),
            "source_get_handle_name_absent_from_pinned_binary": True,
            "computed_dynamic_lookup_absence_proven": False,
            "scope": "Only pinned completion-port read/write sources monitor F_DUPFD_CLOEXEC leases; original fd/context/event callback unchanged; duplicate closes after genuine cancel callback",
            "limitations": ["source_get_handle would expose the duplicate for these scoped sources; audited native callbacks use context.",
                            "Unknown callers/source types pass through; unexpected cancel setters on an owned source fail explicitly.",
                            "Native caller has no NULL checks for create failure; no successful source is fabricated.",
                            "Host lifecycle tests do not establish iPad runtime success."]}
    def run(argv, label):
        result = subprocess.run(argv, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (output / (label + ".log")).write_text(result.stdout + result.stderr)
        report["commands"].append({"stage": label, "exit_code": result.returncode, "log": label + ".log"})
        if result.returncode:
            raise RuntimeError("Build/check failed; see " + label + ".log")
        return result.stdout
    if ipc_record:
        # Keep a byte-identical copy for portable validation of this package.
        # Bundling reuses the already staged game copy, never a second image.
        for name in (steam_ipc_build.FILE, steam_ipc_build.PROFILE):
            shutil.copy2(game_dir / name, output / name)
        report["shared_steam_ipc"] = ipc_record
        report["required_existing_game_libraries"] += [
            {"file": name, "sha256": game_records[name]["sha256"]}
            for name in (steam_ipc_build.FILE, "TFMlibSystem.dylib")]
    mapping = {}
    try:
        sdk = Path(run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], "sdk").strip())
        with tempfile.TemporaryDirectory(prefix="steam-boundary-modules-", dir=output.parent) as cache:
            for provider, library, requested in selected:
                file = NAMES[provider]; target = "@rpath/" + file
                inherited = requested & INHERITED.get(provider, set())
                direct = requested & DIRECT[provider]
                failfast = requested - direct - inherited
                if failfast - (KNOWN[provider] - DIRECT[provider] - INHERITED.get(provider, set())):
                    raise ValueError("Unreviewed stub request")
                lines = ['#include "UnimplementedBoundary.h"']
                for index, symbol in enumerate(sorted(failfast)):
                    if not re.fullmatch(r"_[A-Za-z][A-Za-z0-9_]*", symbol):
                        raise ValueError("Unsafe non-function fail-fast symbol")
                    function = f"TFMSteamUnsupported_{provider}_{index}"
                    lines += [f'__attribute__((noreturn)) void {function}(void) __asm__({json.dumps(symbol)});', f'void {function}(void) {{ TFMAbortUnimplementedBoundary({json.dumps("Steam" + provider)}, {json.dumps(symbol)}); }}']
                source = generated / (provider + "Boundary.m"); source.write_text("\n".join(lines) + "\n")
                sources = [source] + ([STEAM / SOURCES[provider]] if provider in SOURCES else [])
                if provider == "libSystem" and dispatch_leases:
                    sources.append(STEAM / "SteamDispatchCompat.m")
                reexport_libraries = []
                if provider in GAME_REEXPORT:
                    reexport_libraries.append(game_dir / GAME_REEXPORT[provider])
                if provider == "Cocoa":
                    reexport_libraries.append(output / NAMES["AppKit"])
                if provider == "libSystem":
                    if ipc_record:
                        reexport_libraries.append(game_dir / steam_ipc_build.FILE)
                    reexport_libraries.append(sdk / "usr/lib/libSystem.tbd")
                command = ["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", str(sdk),
                           "-miphoneos-version-min=15.0", "-fobjc-arc", "-fmodules", "-dynamiclib", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
                           "-fmodules-cache-path=" + cache, "-I", str(ROOT / "compat"), "-framework", "Foundation", "-framework", "UIKit",
                           "-Wl,-install_name," + target, "-Wl,-compatibility_version,1000.0", "-Wl,-current_version,1000.0"]
                for path in reexport_libraries:
                    command.append("-Wl,-reexport_library," + str(path))
                if provider == "CoreServices":
                    command.append("-Wl,-reexport_framework,CoreServices")
                if provider == "Cocoa":
                    command.append("-Wl,-reexport_framework,Foundation")
                command += [str(path) for path in sources] + ["-o", str(output / file)]
                run(command, provider + "-compile")
                exported = common.export_names(run(["xcrun", "nm", "-arch", "arm64", "-gU", str(output / file)], provider + "-exports"))
                if requested - inherited - exported:
                    raise RuntimeError("Missing direct exports in " + provider)
                if provider == "libSystem" and dispatch_leases and DISPATCH_EXPORTS - exported:
                    raise RuntimeError("Dispatch lifecycle exports missing")
                if inherited:
                    inherited_exports = common.export_names(run(["xcrun", "nm", "-arch", "arm64", "-gU", str(game_dir / GAME_REEXPORT[provider])], provider + "-inherited-exports"))
                    if inherited - inherited_exports:
                        raise RuntimeError("Missing inherited game exports in " + provider)
                loads = run(["xcrun", "otool", "-l", str(output / file)], provider + "-load-commands")
                reexports = common.reexport_paths(loads)
                if provider == "libSystem" and ipc_record:
                    steam_ipc_build.validate_reexport_order(reexports)
                for path in reexport_libraries:
                    expected = "/usr/lib/libSystem.B.dylib" if path.suffix == ".tbd" else "@rpath/" + path.name
                    if expected not in reexports:
                        raise RuntimeError("Missing expected reexport in " + provider)
                for original in set(library.get("original_paths", [])) | {library["original_path"], library["runtime_path"]}:
                    mapping[original] = "@loader_path/" + file
                report["boundaries"].append({"provider": provider, "file": file, "sha256": sha(output / file), "install_name": target,
                    "requested_missing": sorted(requested), "direct_scoped_service_data_or_class_exports": sorted(direct),
                    "inherited_existing_game_exports": sorted(inherited), "failfast_exports": sorted(failfast),
                    "verified_reexports": reexports, "all_direct_exports": sorted(exported),
                    "shared_available_runtime_overrides": sorted({entry["import"] for entry in library["symbols"]} & steam_ipc_build.SEMAPHORE_EXPORTS) if provider == "libSystem" and ipc_record else [],
                    "dispatch_resource_lifecycle_overrides": sorted(DISPATCH_EXPORTS) if provider == "libSystem" and dispatch_leases else [],
                    "sources": [{"path": "generated/" + path.name if path.parent == generated else "compat/steam/" + path.name, "sha256": sha(path)} for path in sources]})
        # Apply to the private original ARM64 images on a later authorized pass,
        # not to the installed Steam client. Includes normalized path spellings.
        per_image = {}
        for image in client["images"]:
            per_image[image["source_relative"]] = {dep["original"]: mapping.get(dep["original"], mapping.get(dep["target"], dep["target"])) for dep in image["dependencies"] if dep["kind"] == "system"}
        report["requested_missing_count"] = sum(len(item["requested_missing"]) for item in report["boundaries"])
        report["failfast_count"] = sum(len(item["failfast_exports"]) for item in report["boundaries"])
        report["inherited_count"] = sum(len(item["inherited_existing_game_exports"]) for item in report["boundaries"])
        report["source_header_sha256"] = {"compat/steam/AppPresence.h": sha(STEAM / "AppPresence.h"), "compat/UnimplementedBoundary.h": sha(ROOT / "compat/UnimplementedBoundary.h"), "compat/steam/constants.json": sha(STEAM / "constants.json")}
        if dispatch_leases:
            if dispatch_sources != {"compat/steam/" + name: sha(STEAM / name) for name in ("SteamDispatchCompat.h", "SteamDispatchCompat.m")}:
                raise RuntimeError("Dispatch lifecycle sources changed during build")
            report["source_header_sha256"]["compat/steam/SteamDispatchCompat.h"] = dispatch_sources["compat/steam/SteamDispatchCompat.h"]
        report["status"] = "built_steam_client_load_boundaries_not_loaded"
        report["steam_ipc_runtime_enabled"] = bool(ipc_record)
        if ipc_record:
            steam_ipc_build.validate(output, ipc_record)
        write(output / "dependency-map.json", mapping)
        write(output / "client-dependency-maps.json", per_image)
        write(output / "build-report.json", report)
        (output / "INCOMPLETE").unlink()
    except Exception as error:
        report["error_type"] = type(error).__name__
        write(output / "build-report.json", report)
        raise
    print(json.dumps({"status": report["status"], "boundaries": len(report["boundaries"]), "requested_missing": report["requested_missing_count"], "failfast": report["failfast_count"], "inherited": report["inherited_count"], "client_loaded": False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--survey", required=True, type=Path)
    parser.add_argument("--client-stage", required=True, type=Path)
    parser.add_argument("--game-boundaries", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--dispatch-leases", action="store_true", help="Enable exact-client completion-port source descriptor leases (requires shared Steam IPC)")
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, OSError, KeyError, RuntimeError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
