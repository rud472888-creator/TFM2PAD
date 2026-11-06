#!/usr/bin/env python3
"""Stage eight pinned Steam binaries privately for later iOS load diagnostics.

Does not load client code, call CreateInterface, start IPC, log in, read account
state, or modify installed Steam files. The existing metadata adapter applies
ad-hoc signatures to generated copies; no identity/profile signing or install.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import portkit
import steam_ipc_build

ALLOWLIST = (
    "MacOS/steamclient.dylib", "MacOS/libaudio.dylib", "MacOS/libvstdlib_s.dylib",
    "MacOS/libtier0_s.dylib", "MacOS/crashhandler.dylib",
    "Frameworks/Breakpad.framework/Versions/A/Breakpad",
    "Frameworks/Breakpad.framework/Versions/A/Resources/breakpadUtilities.dylib",
    "MacOS/ipcserver",
)
PATH_ALIASES = {
    "MacOS/Frameworks/Breakpad.framework/Versions/A/Breakpad": "Frameworks/Breakpad.framework/Versions/A/Breakpad",
    "MacOS/Frameworks/Breakpad.framework/Versions/A/Resources/breakpadUtilities.dylib": "Frameworks/Breakpad.framework/Versions/A/Resources/breakpadUtilities.dylib",
}
ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def thin_arm64(data):
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            cpu, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + index * 20)
            if cpu == 0x100000c:
                if offset + size > len(data):
                    raise ValueError("ARM64 slice is outside the fat image")
                data = data[offset:offset + size]
                break
        else:
            raise ValueError("No ARM64 slice")
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", data, 4)[0] != 0x100000c:
        raise ValueError("Expected a thin ARM64 Mach-O image")
    return data


def sections(data):
    count, commands_size = struct.unpack_from("<II", data, 16)
    offset, found = 32, []
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > 32 + commands_size:
            raise ValueError("Malformed Mach-O load commands")
        if command == 0x19:
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(section_count):
                start = offset + 72 + index * 80
                if start + 80 > offset + size:
                    raise ValueError("Section table is outside segment command")
                name = data[start:start + 16].split(b"\0")[0].decode("ascii")
                segment = data[start + 16:start + 32].split(b"\0")[0].decode("ascii")
                length = struct.unpack_from("<Q", data, start + 40)[0]
                file_offset = struct.unpack_from("<I", data, start + 48)[0]
                if file_offset:
                    if file_offset + length > len(data):
                        raise ValueError("Section is outside image")
                    found.append({"name": segment + "," + name, "offset": file_offset,
                                  "size": length, "sha256": digest(data[file_offset:file_offset + length])})
        offset += size
    return found


def write_report(path, report):
    encoded = json.dumps(report, indent=2) + "\n"
    if "/Users/" in encoded or "/home/" in encoded:
        raise ValueError("Report unexpectedly contains an absolute home path")
    path.write_text(encoded)


def profile_identities(records):
    return {path: (item["sha256"], item["arm64_sha256"]) for path, item in records.items()}


def validate_dispatch_leases(report, by_provider, directory, has_ipc):
    """Validate only the new optional lifecycle adapter; legacy mode stays off."""
    import build_steam_boundaries as dispatch_build
    enabled = report.get("dispatch_descriptor_leases_enabled", False)
    record = report.get("dispatch_descriptor_leases")
    if not isinstance(enabled, bool) or bool(record) != enabled:
        raise ValueError("Dispatch descriptor lease mode/report mismatch")
    system = by_provider.get("libSystem", {})
    recorded_exports = set(system.get("dispatch_resource_lifecycle_overrides", []))
    if not enabled:
        if recorded_exports or dispatch_build.DISPATCH_EXPORTS & set(system.get("all_direct_exports", [])):
            raise ValueError("Dispatch lifecycle exports present without enabled provenance")
        return None
    pins = {"provider": "TFMSteamLibSystem.dylib",
            "client_arm64_sha256": "c608f74c74f6f90b794e47d51bce5421ef0f3dea0681faa8d10ce155c1a1cd09",
            "native_create_return_offsets": [0x10c14b0, 0x10c14cc],
            "native_cancel_setter_return_offsets": [0x10c156c, 0x10c157c],
            "native_event_callback_offset": 0x10c168c,
            "native_cancel_callback_offsets": [0x10c2cc8, 0x10c2ce8]}
    if not has_ipc or system.get("file") != pins["provider"] or any(record.get(key) != value for key, value in pins.items()):
        raise ValueError("Dispatch descriptor lease native profile changed")
    if recorded_exports != dispatch_build.DISPATCH_EXPORTS or set(record.get("exports", [])) != recorded_exports:
        raise ValueError("Dispatch descriptor lease export metadata changed")
    expected = {"compat/steam/" + name: portkit.sha256(ROOT / "compat/steam" / name)
                for name in ("SteamDispatchCompat.h", "SteamDispatchCompat.m")}
    if record.get("source_hashes") != expected:
        raise ValueError("Dispatch descriptor lease source hashes are stale")
    sources = {item["path"]: item["sha256"] for item in system.get("sources", [])}
    if sources.get("compat/steam/SteamDispatchCompat.m") != expected["compat/steam/SteamDispatchCompat.m"] or report.get("source_header_sha256", {}).get("compat/steam/SteamDispatchCompat.h") != expected["compat/steam/SteamDispatchCompat.h"]:
        raise ValueError("Dispatch descriptor lease compile provenance is incomplete")
    env = dict(os.environ)
    names = subprocess.check_output(["xcrun", "nm", "-arch", "arm64", "-gU", str(Path(directory) / pins["provider"])], env=env, text=True)
    actual = {line.split()[-1] for line in names.splitlines() if line.split()}
    if recorded_exports - actual or recorded_exports - set(system.get("all_direct_exports", [])):
        raise ValueError("Dispatch descriptor lease actual exports are missing")
    return record


def validate_steam_boundaries(directory, expected_identities):
    """Validate metadata and bytes only; never dlopen a boundary or client."""
    directory = Path(directory).resolve(strict=True)
    report_path = directory / "build-report.json"
    mapping_path = directory / "dependency-map.json"
    report = json.loads(report_path.read_text())
    if (directory / "INCOMPLETE").exists() or report.get("schema_version") != 1 or report.get("status") != "built_steam_client_load_boundaries_not_loaded":
        raise ValueError("Need a complete Steam runtime boundary build")
    identities = {item["path"]: (item["sha256"], item["arm64_sha256"]) for item in report["source_binary_set"]["images"]}
    if identities != expected_identities:
        raise ValueError("Steam boundaries were surveyed for a different client binary set")
    commands = report.get("commands")
    if not commands or any(item.get("exit_code") != 0 for item in commands):
        raise ValueError("Steam boundary build contains missing/failed commands")
    records = report.get("boundaries", [])
    by_provider, by_file = {}, {}
    for item in records:
        name = item["file"]
        if Path(name).name != name or not name.endswith(".dylib") or name in by_file or item["provider"] in by_provider:
            raise ValueError("Invalid or duplicate Steam boundary filename/provider")
        if item.get("install_name") != "@rpath/" + name:
            raise ValueError("Unexpected Steam boundary install name")
        path = directory / name
        if path.is_symlink() or not path.is_file() or portkit.sha256(path) != item["sha256"]:
            raise ValueError("Steam boundary library changed: " + name)
        requested = set(item["requested_missing"])
        direct = set(item["direct_scoped_service_data_or_class_exports"])
        inherited = set(item["inherited_existing_game_exports"])
        failfast = set(item["failfast_exports"])
        if (direct | inherited | failfast) != requested or direct & inherited or direct & failfast or inherited & failfast:
            raise ValueError("Steam boundary export coverage report is inconsistent")
        if (direct | failfast) - set(item["all_direct_exports"]):
            raise ValueError("Steam boundary direct export verification is incomplete")
        by_provider[item["provider"]], by_file[name] = item, item
    if not records or sum(len(item["requested_missing"]) for item in records) != report.get("requested_missing_count"):
        raise ValueError("Steam boundary missing-export total is inconsistent")
    mapping = json.loads(mapping_path.read_text())
    if not isinstance(mapping, dict) or not mapping:
        raise ValueError("Steam boundary dependency map is empty or malformed")
    covered = set()
    for original, target in mapping.items():
        if not original.startswith(("/System/Library/", "/usr/lib/")):
            raise ValueError("Steam boundary map must rewrite system dependencies only")
        provider = re.sub(r"(?:\.[A-Z0-9]+)*\.dylib$", "", Path(original).name)
        if provider not in by_provider or target != "@loader_path/" + by_provider[provider]["file"]:
            raise ValueError("Steam boundary map does not match its provider report")
        covered.add(provider)
    if covered != set(by_provider):
        raise ValueError("Steam boundary map omits a built provider")
    dependencies = report.get("required_existing_game_libraries", [])
    if not dependencies:
        raise ValueError("Steam boundaries do not identify their existing game dependencies")
    for item in dependencies:
        if Path(item["file"]).name != item["file"] or not item["file"].endswith(".dylib") or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            raise ValueError("Invalid existing game dependency identity")
    ipc = report.get("shared_steam_ipc")
    if bool(ipc) != bool(report.get("steam_ipc_runtime_enabled")):
        raise ValueError("Steam shared IPC mode/report mismatch")
    if ipc:
        steam_ipc_build.validate(directory, ipc)
        dependency_hashes = {item["file"]: item["sha256"] for item in dependencies}
        if dependency_hashes.get(steam_ipc_build.FILE) != ipc["sha256"] or "TFMlibSystem.dylib" not in dependency_hashes:
            raise ValueError("Shared IPC must identify the exact existing IPC/game libSystem images")
        env = dict(os.environ)
        actual_loads = subprocess.check_output(["xcrun", "otool", "-l", str(directory / "TFMSteamLibSystem.dylib")], env=env, text=True)
        # Keep parsing in the shared builder rather than trusting report order.
        import build_loader_boundaries
        actual_reexports = build_loader_boundaries.reexport_paths(actual_loads)
        steam_ipc_build.validate_reexport_order(actual_reexports)
        if actual_reexports != by_provider["libSystem"]["verified_reexports"]:
            raise ValueError("Steam shared IPC reexport report differs from the actual libSystem image")
    dispatch_record = validate_dispatch_leases(report, by_provider, directory, bool(ipc))
    provenance = {"build_report_sha256": portkit.sha256(report_path), "dependency_map_sha256": portkit.sha256(mapping_path),
                  "survey_sha256": report["survey_sha256"], "status": report["status"],
                  "libraries": [{"provider": item["provider"], "file": item["file"], "sha256": item["sha256"], "install_name": item["install_name"]} for item in records],
                  "required_existing_game_libraries": dependencies, "requested_missing_count": report["requested_missing_count"],
                  "failfast_count": report["failfast_count"], "inherited_count": report["inherited_count"],
                  "boundary_libraries_copied_into_this_stage": False,
                  "dependency_mapping_applied": True, "client_loaded": False, "login_performed": False}
    if "dispatch_descriptor_leases_enabled" in report:
        provenance["dispatch_descriptor_leases_enabled"] = dispatch_record is not None
    if dispatch_record:
        provenance["dispatch_descriptor_leases"] = dispatch_record
    if ipc:
        provenance["shared_steam_ipc"] = ipc
    return mapping, provenance


def build(args):
    source = args.source.resolve(strict=True)
    profile_path = args.profile.resolve(strict=True)
    profile = json.loads(profile_path.read_text())
    records = {item["path"]: item for item in profile["installed_client"]["images"]}
    if set(records) != set(ALLOWLIST):
        raise ValueError("Profile must contain exactly the eight reviewed binary paths")
    boundary_directory = getattr(args, "boundaries", None)
    boundary_mapping, boundary_provenance = {}, None
    if boundary_directory:
        boundary_mapping, boundary_provenance = validate_steam_boundaries(boundary_directory, profile_identities(records))
    boundary_providers = {item["provider"] for item in boundary_provenance["libraries"]} if boundary_provenance else set()
    output = args.output.resolve()
    if output.exists():
        raise ValueError("Use a fresh output directory; previous stages are preserved")
    if output == source or source in output.parents:
        raise ValueError("Output must be outside installed Steam")
    if output == ROOT or ROOT in output.parents:
        raise ValueError("Private Steam binaries must be staged outside deliverable outputs")
    adapter_path = ROOT / "vendor/agepad/prepare-de-load-image.py"
    if portkit.sha256(adapter_path) != portkit.ADAPTER_SHA256:
        raise ValueError("Vendored metadata adapter digest differs from the pinned toolkit input")
    # Read only explicitly allowed binaries and reviewed duplicate-path hashes;
    # never scan the client tree or read configuration/account files.
    originals, arm64 = {}, {}
    for relative in ALLOWLIST:
        path = source / relative
        if not path.is_file() or not path.resolve().is_relative_to(source):
            raise ValueError("Missing binary or path escapes source: " + relative)
        blob = path.read_bytes()
        thin = thin_arm64(blob)
        record = records[relative]
        if len(blob) != record["size"] or digest(blob) != record["sha256"] or len(thin) != record["arm64_size"] or digest(thin) != record["arm64_sha256"]:
            raise ValueError("Installed binary changed from feasibility pin: " + relative)
        originals[relative], arm64[relative] = blob, thin
    verified_aliases = []
    for alias, canonical in PATH_ALIASES.items():
        alias_path = source / alias
        if not alias_path.is_file() or not alias_path.resolve().is_relative_to(source) or portkit.sha256(alias_path) != records[canonical]["sha256"]:
            raise ValueError("Duplicate vendor path no longer matches reviewed binary: " + alias)
        verified_aliases.append({"path": alias, "canonical_source_relative": canonical, "sha256": records[canonical]["sha256"], "copied_separately": False})
    output.mkdir(parents=True)
    marker = output / "INCOMPLETE"
    marker.write_text("Client staging incomplete. Do not load.\n")
    frameworks = output / "Frameworks"
    frameworks.mkdir()
    report = {"schema_version": 1, "status": "incomplete", "recorded_at": datetime.now(timezone.utc).isoformat(),
              "source_relative": "Steam.AppBundle/Steam/Contents", "profile_sha256": portkit.sha256(profile_path),
              "app_id": 3009300, "images": [], "system_dependencies": [],
              "hash_verified_dependency_path_aliases": verified_aliases,
              "metadata_adapter_sha256": portkit.ADAPTER_SHA256, "vendor_sections_preserved": False,
              "scope": {"installed_client_modified": False, "client_code_executed": False, "ipc_started": False,
                        "login_performed": False, "config_account_or_token_files_read": False,
                        "allowlisted_binary_count": len(ALLOWLIST), "assets_or_account_state_copied": False,
                        "generated_copy_signing": "Existing metadata adapter applies ad-hoc output signatures; no identity/profile signing or installation"},
              "limitations": ["Prepared images are not a working Steam engine or a successful load.",
                              "No system framework or missing API implementation is supplied by this stage.",
                              "All imported APIs need a current real-iPad client survey; game-only survey is insufficient.",
                              "ABI/version, local IPC, engine frame pump, server protocol, sign-in and genuine ownership remain untested.",
                              "AoE-specific SteamModuleCompat and app813780 configuration are not used."]}
    if boundary_provenance:
        report["boundary_package"] = boundary_provenance
        report["limitations"][1] = "Separate Steam boundary libraries are required when bundling; seventeen unknown functions still fail fast. Load/constructor behavior is unverified."
    env = dict(os.environ)
    def xrun(*command):
        return subprocess.check_output(["xcrun", *command], env=env, text=True)
    names = {relative: ("TFMSteamIPCHelper.dylib" if relative == "MacOS/ipcserver" else
                       Path(relative).name if relative.endswith(".dylib") else Path(relative).name + ".dylib") for relative in ALLOWLIST}
    if len(set(names.values())) != len(names):
        raise ValueError("Flattened vendor output names collide")
    try:
        sdk = Path(xrun("--sdk", "iphoneos", "--show-sdk-path").strip())
        report["inspection_sdk"] = sdk.name
        for relative in ALLOWLIST:
            for base, blob in (("originals", originals[relative]), ("arm64", arm64[relative])):
                destination = output / base / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(blob)
                if digest(destination.read_bytes()) != digest(blob):
                    raise ValueError("Private binary copy verification failed: " + relative)
        spec = importlib.util.spec_from_file_location("tfm_steam_metadata_adapter", adapter_path)
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        systems = {}
        for relative in ALLOWLIST:
            private = output / "arm64" / relative
            dependency_map, dependencies = {}, []
            deps = re.findall(r"^\s+([^\n]+?) \(compatibility version", xrun("otool", "-arch", "arm64", "-L", str(private)), re.M)
            install_lines = xrun("otool", "-D", str(private)).splitlines()[1:]
            own_id = install_lines[0].strip() if install_lines else None
            for dependency in deps:
                if dependency.startswith(("/System/Library/", "/usr/lib/")):
                    normalized = re.sub(r"/Versions/[^/]+/", "/", dependency)
                    mapped = boundary_mapping.get(dependency, boundary_mapping.get(normalized, normalized))
                    provider = re.sub(r"(?:\.[A-Z0-9]+)*\.dylib$", "", Path(normalized).name)
                    if provider in boundary_providers and mapped == normalized:
                        raise ValueError("Boundary mapping omitted a client system dependency: " + provider)
                    dependency_map[dependency] = mapped
                    framework = re.search(r"/([^/]+)\.framework/", normalized)
                    if framework:
                        sdk_present = (sdk / "System/Library/Frameworks" / (framework[1] + ".framework") / (framework[1] + ".tbd")).is_file()
                    else:
                        sdk_present = (sdk / normalized.lstrip("/")).with_suffix(".tbd").is_file()
                    item = systems.setdefault(normalized, {"path": normalized, "sdk_stub_present": sdk_present, "images": [], "actual_device_symbol_survey_required": True})
                    item["images"].append(relative)
                    dependencies.append({"original": dependency, "target": mapped, "kind": "system", "sdk_stub_present": sdk_present})
                    continue
                if not dependency.startswith(("@loader_path/", "@rpath/", "@executable_path/")):
                    raise ValueError("Unreviewed dependency path in " + relative)
                tail = dependency.split("/", 1)[1]
                candidates = [(source / relative).parent / tail, source / tail, source / "Frameworks" / tail, source / "MacOS" / tail]
                resolved = None
                for candidate in candidates:
                    try:
                        candidate_relative = str(candidate.resolve().relative_to(source))
                    except ValueError:
                        continue
                    if candidate_relative in records:
                        resolved = candidate_relative
                        break
                    if candidate_relative in PATH_ALIASES:
                        resolved = PATH_ALIASES[candidate_relative]
                        break
                if resolved is None:
                    raise ValueError("Vendor dependency is not in the eight-file allowlist: " + dependency)
                target = "@rpath/" + names[resolved] if dependency == own_id else "@loader_path/" + names[resolved]
                dependency_map[dependency] = target
                dependencies.append({"original": dependency, "target": target, "kind": "install_name" if dependency == own_id else "vendor", "source_relative": resolved})
            destination = frameworks / names[relative]
            # Every path passed to prepare is an owned private copy.
            prepared = adapter.prepare(private, destination, platform="ios-device", dependency_map=dependency_map)
            if relative == "MacOS/ipcserver":
                # The generic adapter adds Engine.dylib for MH_EXECUTE. Give the
                # helper a unique ID through a second metadata-only adapter pass.
                second = frameworks / (names[relative] + ".retargeted")
                adapter.prepare(destination, second, platform="ios-device", dependency_map={"@rpath/Engine.dylib": "@rpath/" + names[relative]})
                second.replace(destination)
            original_sections = sections(arm64[relative])
            if sections(destination.read_bytes()) != original_sections or prepared.get("instructions_changed") or not all(section["equal"] for section in prepared["sections"]):
                raise ValueError("Original section bytes changed: " + relative)
            build = xrun("vtool", "-show-build", str(destination))
            if not re.search(r"platform\s+IOS\s", build):
                raise ValueError("Staged binary is not marked as an iOS device image")
            final_id = xrun("otool", "-D", str(destination)).splitlines()[1:]
            if final_id != ["@rpath/" + names[relative]]:
                raise ValueError("Unexpected staged install name: " + relative)
            report["images"].append({"source_relative": relative, "original_sha256": digest(originals[relative]),
                "arm64_sha256": digest(arm64[relative]), "private_original": "originals/" + relative,
                "private_arm64": "arm64/" + relative, "output": "Frameworks/" + names[relative],
                "output_sha256": portkit.sha256(destination), "output_size": destination.stat().st_size,
                "install_name": final_id[0], "platform": "IOS", "dependencies": dependencies,
                "instructions_changed": False, "original_sections": original_sections})
        # Source updates during copying invalidate the entire candidate.
        for relative in ALLOWLIST:
            if portkit.sha256(source / relative) != records[relative]["sha256"]:
                raise ValueError("Installed Steam changed during staging: " + relative)
        for alias, canonical in PATH_ALIASES.items():
            if portkit.sha256(source / alias) != records[canonical]["sha256"]:
                raise ValueError("Duplicate dependency path changed during staging: " + alias)
        if boundary_provenance:
            _, after = validate_steam_boundaries(boundary_directory, profile_identities(records))
            if after != boundary_provenance:
                raise ValueError("Steam boundary package changed during staging")
        report["system_dependencies"] = sorted(systems.values(), key=lambda item: item["path"])
        report["required_framework_boundaries"] = [item["path"] for item in report["system_dependencies"] if not item["sdk_stub_present"]]
        report["vendor_sections_preserved"] = True
        report["source_hashes_verified_before_and_after"] = True
        report["status"] = "staged_ios_client_requires_runtime_boundaries"
        write_report(output / "steam-client-stage.json", report)
        marker.unlink()
    except Exception as error:
        # Avoid serializing traceback/system error paths into metadata reports.
        report["error_type"] = type(error).__name__
        report["status"] = "incomplete"
        write_report(output / "steam-client-stage.json", report)
        raise
    print(json.dumps({"status": report["status"], "images": len(report["images"]), "absent_sdk_frameworks": len(report["required_framework_boundaries"]), "client_executed": False, "login_performed": False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Installed Steam Contents; eight pinned binaries are copied and explicit duplicate framework paths hash-checked")
    parser.add_argument("--profile", type=Path, default=ROOT / "evidence/steam-engine-feasibility.json")
    parser.add_argument("--boundaries", type=Path, help="Optional complete Steam boundary package; validates hashes and remaps system dependencies")
    parser.add_argument("--output", required=True, type=Path, help="Fresh private work directory, outside deliverables and installed Steam")
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
