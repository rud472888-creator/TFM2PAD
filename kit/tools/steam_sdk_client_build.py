"""SDK-only libSystem provider packaging; never execute Steam or provider code."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

import portkit
import steam_init_bridge_build as sdk
import steam_ipc_build
from stage_steam_client import thin_arm64, sections

ROOT = Path(__file__).resolve().parents[1]
FILE = "TFMSteamSDKClientBoundary.dylib"
INSTALL_NAME = "@rpath/" + FILE
SYSTEM_FILE = "TFMlibSystem.dylib"
SYSTEM_ID = "@rpath/" + SYSTEM_FILE
SOURCE_NAMES = ("SteamLaunchPolicy.h", "SteamSDKClientBoundary.h", "SteamSDKClientBoundary.m", "SteamSDKClientBoundary.S")
EXPORTS = {"_dlsym", "_TFMSteamSDKClientBoundaryConfigure", "_TFMSteamSDKClientBoundarySnapshot"}


def source_hashes():
    result = {}
    for name in SOURCE_NAMES:
        path = ROOT / "compat/steam" / name
        if path.is_symlink() or not path.is_file(): raise ValueError("Missing/non-regular SDK client boundary source: " + name)
        result["compat/steam/" + name] = portkit.sha256(path)
    return result


def common_input(directory, report):
    """Validate the exact shared-Mach-IPC/semaphore provider we will reexport."""
    if not report.get("steam_ipc_runtime_enabled") or not report.get("shared_steam_ipc"):
        raise ValueError("SDK client-order fix requires complete shared Steam IPC runtime boundaries")
    directory = Path(directory)
    steam_ipc_build.validate(directory, report["shared_steam_ipc"])
    records = [item for item in report["boundaries"] if item["file"] == SYSTEM_FILE]
    if len(records) != 1: raise ValueError("Expected exactly one existing game libSystem boundary")
    path = directory / SYSTEM_FILE
    if path.is_symlink() or portkit.sha256(path) != records[0]["sha256"]:
        raise ValueError("Existing game libSystem changed after build")
    info = sdk.metadata(path.read_bytes())
    if info["install_names"] != [SYSTEM_ID]: raise ValueError("Unexpected game libSystem install name")
    steam_ipc_build.validate_reexport_order(info["reexports"])
    if info["reexports"] != records[0].get("verified_reexports"):
        raise ValueError("Game libSystem reexport provenance differs from its actual image")
    shared = report["shared_steam_ipc"]
    return {"system_file": SYSTEM_FILE, "system_sha256": records[0]["sha256"], "system_reexports": info["reexports"],
            "shared_ipc_file": steam_ipc_build.FILE, "shared_ipc_sha256": shared["sha256"], "shared_ipc_sources": shared["source_hashes"]}


def game_input(path, expected_record):
    path = Path(path)
    if path.is_symlink() or not path.is_file(): raise ValueError("Game must be a regular original input")
    raw = path.read_bytes()
    if sdk.sha(raw) != expected_record.get("sha256") or len(raw) != expected_record.get("size"):
        raise ValueError("Original game changed before SDK client boundary staging")
    thin = thin_arm64(raw); original_sections = sections(thin)
    if not original_sections: raise ValueError("Original game has no verified file-backed sections")
    return {"universal_sha256": sdk.sha(raw), "arm64_sha256": sdk.sha(thin), "sections": original_sections}


def inspect_common(frameworks, expected):
    frameworks = Path(frameworks)
    for file, digest in ((SYSTEM_FILE, expected["system_sha256"]), (steam_ipc_build.FILE, expected["shared_ipc_sha256"])):
        path = frameworks / file
        if path.is_symlink() or not path.is_file() or portkit.sha256(path) != digest:
            raise ValueError("Staged common IPC/system library differs from pinned runtime: " + file)
    info = sdk.metadata((frameworks / SYSTEM_FILE).read_bytes())
    if info["install_names"] != [SYSTEM_ID] or info["reexports"] != expected["system_reexports"]:
        raise ValueError("Staged common libSystem reexport chain changed")
    steam_ipc_build.validate_reexport_order(info["reexports"])


def inspect_provider(path, run):
    data = Path(path).read_bytes(); info = sdk.metadata(data)
    if info["filetype"] != 6 or info["platforms"] != [2] or info["install_names"] != [INSTALL_NAME] or info["reexports"] != [SYSTEM_ID]:
        raise ValueError("SDK-only provider must be iOS ARM64 and reexport exactly the existing game libSystem")
    if info["automatic_initializers"]: raise ValueError("SDK-only provider must not initialize automatically")
    names, _ = sdk.exported(path, run)
    if set(names) != EXPORTS: raise ValueError("SDK-only provider has unexpected direct exports")
    return {"file": FILE, "sha256": sdk.sha(data), "size": len(data), "install_name": INSTALL_NAME,
            "direct_exports": names, "reexports": info["reexports"], "platform": "ios-device-arm64"}


def inspect_images(frameworks, original_sdk, original_game, init_bridge, run, *, layout_profile=None):
    frameworks = Path(frameworks)
    name = sdk.ORIGINAL_FILE if init_bridge else sdk.WRAPPER_FILE
    path = frameworks / name
    if path.is_symlink() or not path.is_file(): raise ValueError("Expected regular staged original SDK")
    data = path.read_bytes(); info = sdk.metadata(data)
    wanted_id = sdk.ORIGINAL_ID if init_bridge else "@loader_path/libsteam_api.dylib"
    if info["filetype"] != 6 or info["platforms"] != [2] or info["install_names"] != [wanted_id] or info["uuids"] != [sdk.SDK_UUID]:
        raise ValueError("SDK filename/install identity differs from selected init bridge mode")
    if info["loads"].count(INSTALL_NAME) != 1 or SYSTEM_ID in info["loads"] or "/usr/lib/libSystem.B.dylib" in info["loads"]:
        raise ValueError("Only original SDK libSystem dependency must select the new SDK-only provider")
    if len(original_sdk["sections"]) != 12 or sections(data) != original_sdk["sections"]:
        raise ValueError("Original SDK code/data sections changed")
    if sdk.sha(data[sdk.SDK_INIT_OFFSET:sdk.SDK_INIT_OFFSET + 64]) != sdk.SDK_INIT_FIRST64_SHA:
        raise ValueError("Original SDK init instructions changed")
    exports, digest = sdk.exported(path, run)
    if len(exports) != sdk.SDK_EXPORT_COUNT or digest != sdk.SDK_EXPORT_SHA:
        raise ValueError("Original SDK public export table changed")
    game = frameworks / "TeamfightManager2.dylib"
    game_bytes = game.read_bytes()
    if layout_profile is not None:
        # The SDK-only stage precedes the explicit UI mod. Reconstruct its
        # exact preimage; validate() still compares the whole original staged
        # hash, and the caller separately verifies the complete layout stage.
        import stage_ipad_layout as layout
        game_bytes, _ = layout.patch_game(game_bytes, json.loads(Path(layout_profile).read_text()), reverse=True)
    game_info = sdk.metadata(game_bytes)
    if sections(game_bytes) != original_game["sections"] or INSTALL_NAME in game_info["loads"] or SYSTEM_ID not in game_info["loads"]:
        raise ValueError("Game sections or unchanged common-libSystem dependency were not preserved")
    return {"sdk_file": name, "sdk_sha256": sdk.sha(data), "sdk_install_name": wanted_id,
            "sdk_original_sections_verified": 12, "sdk_export_count": len(exports), "sdk_libsystem_provider": INSTALL_NAME,
            "game_sha256": sdk.sha(game_bytes), "game_original_sections_verified": len(original_game["sections"]),
            "game_libsystem_provider": SYSTEM_ID, "original_instructions_changed": False}


def build(frameworks, common):
    frameworks = Path(frameworks); destination = frameworks / FILE
    if destination.exists() or destination.is_symlink(): raise ValueError("Refusing to overwrite SDK-only provider")
    inspect_common(frameworks, common)
    expected_sources = source_hashes(); commands = []
    env = dict(os.environ)
    def run(argv):
        result = subprocess.run(argv, env=env, text=True, capture_output=True)
        commands.append({"tool": Path(argv[0]).name, "exit_code": result.returncode})
        if result.returncode: raise RuntimeError("SDK-only provider build/inspection failed: " + result.stderr[:3000])
        return result.stdout
    sdk_path = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
    with tempfile.TemporaryDirectory(prefix="tfm-sdk-client-", dir=frameworks.parent.parent) as temporary:
        object_path = Path(temporary) / "SteamSDKClientBoundary.o"
        run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk_path,
             "-miphoneos-version-min=15.0", "-Wall", "-Wextra", "-Werror", "-c",
             str(ROOT / "compat/steam/SteamSDKClientBoundary.S"), "-o", str(object_path)])
        run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk_path,
             "-miphoneos-version-min=15.0", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-dynamiclib",
             "-framework", "Foundation", "-Wl,-install_name," + INSTALL_NAME,
             "-Wl,-reexport_library," + str(frameworks / SYSTEM_FILE),
             str(ROOT / "compat/steam/SteamSDKClientBoundary.m"), str(object_path), "-o", str(destination)])
    run(["codesign", "--force", "--sign", "-", str(destination)])
    provider = inspect_provider(destination, run)
    inspect_common(frameworks, common)
    if source_hashes() != expected_sources: raise ValueError("SDK client boundary sources changed during compilation")
    return {"schema_version": 1, "status": "built_optional_sdk_client_provider_not_executed", "provider": provider,
            "source_hashes": expected_sources, "common_runtime": common, "commands": commands,
            "sdk_executed": False, "provider_configured": False, "authentication_performed": False,
            "scope": "SDK-only libSystem dependency metadata; no game/client instruction patch or synthesized user/interface pointer"}


def finish(frameworks, report, original_sdk, original_game, init_bridge, run=None):
    if run is None:
        env = dict(os.environ)
        def run(argv): return subprocess.check_output(argv, env=env, text=True)
    report.update(original_sdk_input=original_sdk, original_game_input=original_game, init_bridge_enabled=bool(init_bridge),
                  staged_images=inspect_images(frameworks, original_sdk, original_game, init_bridge, run))
    return report


def validate(frameworks, report, inputs, init_bridge, run=None, *, layout_profile=None):
    if not isinstance(report, dict) or report.get("schema_version") != 1 or report.get("status") != "built_optional_sdk_client_provider_not_executed":
        raise ValueError("SDK-only provider build provenance is missing")
    if report.get("source_hashes") != source_hashes() or report.get("source_hashes") != inputs["source_hashes"]:
        raise ValueError("SDK-only provider source provenance changed")
    if report.get("common_runtime") != inputs["common_runtime"] or report.get("original_sdk_input") != inputs["original_sdk_input"] or report.get("original_game_input") != inputs["original_game_input"] or report.get("init_bridge_enabled") is not bool(init_bridge):
        raise ValueError("SDK-only provider runtime/input/mode differs from explicit plan")
    if not report.get("commands") or any(item.get("exit_code") != 0 for item in report["commands"]):
        raise ValueError("SDK-only provider build commands were not completed")
    if any(report.get(name) is not False for name in ("sdk_executed", "provider_configured", "authentication_performed")):
        raise ValueError("SDK-only packaging provenance must not claim runtime execution")
    if run is None:
        env = dict(os.environ)
        def run(argv): return subprocess.check_output(argv, env=env, text=True)
    path = Path(frameworks) / FILE
    if path.is_symlink() or not path.is_file(): raise ValueError("SDK-only provider must be a regular staged image")
    inspect_common(frameworks, inputs["common_runtime"])
    if inspect_provider(path, run) != report.get("provider"):
        raise ValueError("Staged SDK-only provider differs from built artifact")
    actual = inspect_images(frameworks, inputs["original_sdk_input"], inputs["original_game_input"], init_bridge, run,
                            layout_profile=layout_profile)
    if actual != report.get("staged_images"):
        raise ValueError("Staged SDK/game bytes differ from SDK-only provider provenance")
    return {"sdk_original_sections_verified": 12, "game_original_sections_verified": actual["game_original_sections_verified"],
            "game_section_verification": "restored_layout_preimage" if layout_profile is not None else "current_bytes",
            "sdk_only_provider_verified": INSTALL_NAME, "common_mach_ipc_semaphore_reexport_preserved": True, "sdk_executed": False}
