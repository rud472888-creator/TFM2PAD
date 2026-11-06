"""Build/inspect an opt-in SDK init wrapper; never load or execute SDK code."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

import portkit
from stage_steam_client import thin_arm64, sections

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL_FILE = "TFMOriginalSteamAPI.dylib"
ORIGINAL_ID = "@rpath/" + ORIGINAL_FILE
WRAPPER_FILE = "libsteam_api.dylib"
WRAPPER_ID = "@rpath/" + WRAPPER_FILE
SOURCE_NAMES = ("SteamLaunchPolicy.h", "SteamInitBridge.h", "SteamInitBridge.m")
WRAPPER_EXPORTS = {"_SteamInternal_SteamAPI_Init", "_TFMSteamConfigureInitCoordinator"}
SDK_UNIVERSAL_SHA = "363ab50ce9bf4680d8ddb8c6142e566854803f831769fab0428867b9994d0520"
SDK_ARM64_SHA = "c3c981a256cd2e16d3951101410386d2c910f8b312bf0549b7a3625089617c53"
SDK_UUID = "fca0302280d73c019d1242b887a94e65"
SDK_INIT_OFFSET = 0x38c8
SDK_INIT_FIRST64_SHA = "19fdea73257a51133d7751403b41b6b691ba77e3ea8da8a8e06390f4023ffea1"
SDK_EXPORT_COUNT = 1076
SDK_EXPORT_SHA = "ac3877f19449a0a675bdbb2933bef69ceb230b84094cc57d99ceb59c1b217c98"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source_hashes():
    result = {}
    for name in SOURCE_NAMES:
        path = ROOT / "compat/steam" / name
        if path.is_symlink() or not path.is_file(): raise ValueError("Missing/non-regular Steam init bridge source: " + name)
        result["compat/steam/" + name] = portkit.sha256(path)
    return result


def metadata(data):
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", data, 4)[0] != 0x100000c:
        raise ValueError("Expected thin ARM64 Mach-O")
    count, length = struct.unpack_from("<II", data, 16)
    if length > len(data) - 32 or count > length // 8:
        raise ValueError("Invalid Mach-O command table")
    offset = 32; end = 32 + length
    result = {"filetype": struct.unpack_from("<I", data, 12)[0], "install_names": [], "loads": [], "reexports": [], "platforms": [], "uuids": [], "automatic_initializers": False}
    for _ in range(count):
        if offset + 8 > end: raise ValueError("Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end: raise ValueError("Invalid Mach-O command size")
        if command in (0xc, 0xd, 0x80000018, 0x8000001f, 0x80000023):
            if size < 24: raise ValueError("Truncated dylib command")
            start = struct.unpack_from("<I", data, offset + 8)[0]
            if start < 24 or start >= size: raise ValueError("Invalid dylib name offset")
            value = data[offset + start:offset + size]
            if b"\0" not in value: raise ValueError("Unterminated dylib name")
            name = value.split(b"\0", 1)[0].decode("utf-8")
            result["install_names" if command == 0xd else "loads"].append(name)
            if command == 0x8000001f: result["reexports"].append(name)
        elif command == 0x32:
            if size < 24: raise ValueError("Truncated build-version command")
            result["platforms"].append(struct.unpack_from("<I", data, offset + 8)[0])
        elif command == 0x1b:
            if size != 24: raise ValueError("Invalid UUID command")
            result["uuids"].append(data[offset + 8:offset + 24].hex())
        elif command in (0x11, 0x1a): result["automatic_initializers"] = True
        elif command == 0x19:
            if size < 72: raise ValueError("Truncated segment command")
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + nsects * 80 > size: raise ValueError("Truncated section table")
            for index in range(nsects):
                flags = struct.unpack_from("<I", data, offset + 72 + index * 80 + 64)[0]
                if flags & 0xff in (0x9, 0x16): result["automatic_initializers"] = True
        offset += size
    if offset != end: raise ValueError("Mach-O command length mismatch")
    return result


def inspect_input_sdk(path, expected_record):
    path = Path(path)
    if path.is_symlink() or not path.is_file(): raise ValueError("SDK must be a regular owned input file")
    raw = path.read_bytes()
    if sha(raw) != SDK_UNIVERSAL_SHA or expected_record.get("sha256") != SDK_UNIVERSAL_SHA or len(raw) != expected_record.get("size"):
        raise ValueError("Unreviewed original SDK for Steam init bridge; audit the new SDK before updating its explicit pins")
    thin = thin_arm64(raw)
    if sha(thin) != SDK_ARM64_SHA: raise ValueError("Original SDK ARM64 slice differs from reviewed pin")
    info = metadata(thin)
    if info["uuids"] != [SDK_UUID] or sha(thin[SDK_INIT_OFFSET:SDK_INIT_OFFSET + 64]) != SDK_INIT_FIRST64_SHA:
        raise ValueError("Original SDK UUID/init-code guard mismatch")
    original_sections = sections(thin)
    if len(original_sections) != 12: raise ValueError("Reviewed original SDK must have exactly twelve file-backed sections")
    return {"universal_sha256": SDK_UNIVERSAL_SHA, "arm64_sha256": SDK_ARM64_SHA, "uuid": SDK_UUID,
            "init_offset": SDK_INIT_OFFSET, "init_first64_sha256": SDK_INIT_FIRST64_SHA,
            "sections": original_sections, "export_count": SDK_EXPORT_COUNT, "export_names_sha256": SDK_EXPORT_SHA}


def exported(path, run):
    names = sorted({line.strip() for line in run(["xcrun", "nm", "-arch", "arm64", "-gjU", str(path)]).splitlines() if line.strip().startswith("_")})
    return names, sha(("\n".join(names) + "\n").encode())


def inspect_original(path, original_pin, run):
    data = Path(path).read_bytes(); info = metadata(data)
    if info["filetype"] != 6 or info["install_names"] != [ORIGINAL_ID] or info["platforms"] != [2] or info["uuids"] != [SDK_UUID]:
        raise ValueError("Unique original SDK identity/platform/UUID mismatch")
    if sections(data) != original_pin["sections"] or len(original_pin["sections"]) != 12:
        raise ValueError("Original SDK twelve sections changed")
    if sha(data[SDK_INIT_OFFSET:SDK_INIT_OFFSET + 64]) != SDK_INIT_FIRST64_SHA:
        raise ValueError("Staged original SDK init instructions changed")
    names, digest = exported(path, run)
    if len(names) != SDK_EXPORT_COUNT or digest != SDK_EXPORT_SHA:
        raise ValueError("Original SDK public export table changed")
    return {"file": ORIGINAL_FILE, "sha256": sha(data), "size": len(data), "install_name": ORIGINAL_ID,
            "platform": "ios-device-arm64", "uuid": SDK_UUID, "export_count": len(names), "export_names_sha256": digest}


def inspect_wrapper(path, run):
    data = Path(path).read_bytes(); info = metadata(data)
    if info["filetype"] != 6 or info["install_names"] != [WRAPPER_ID] or info["platforms"] != [2] or info["reexports"] != [ORIGINAL_ID]:
        raise ValueError("SDK wrapper must be iOS ARM64 and reexport exactly the uniquely named original")
    if info["automatic_initializers"]: raise ValueError("SDK wrapper must not have automatic initializer code")
    names, _ = exported(path, run)
    if set(names) != WRAPPER_EXPORTS:
        raise ValueError("SDK wrapper direct exports differ from the two reviewed bridge entrypoints")
    return {"file": WRAPPER_FILE, "sha256": sha(data), "size": len(data), "install_name": WRAPPER_ID,
            "platform": "ios-device-arm64", "direct_exports": names, "reexports": info["reexports"]}


def build(frameworks, original_pin):
    frameworks = Path(frameworks); original = frameworks / ORIGINAL_FILE; wrapper = frameworks / WRAPPER_FILE
    if frameworks.is_symlink() or original.is_symlink() or not original.is_file():
        raise ValueError("Unique original SDK must be a regular staged file")
    if wrapper.exists() or wrapper.is_symlink(): raise ValueError("Refusing to overwrite an existing SDK wrapper")
    expected_sources = source_hashes(); commands = []
    env = dict(os.environ)
    def run(argv):
        result = subprocess.run(argv, env=env, text=True, capture_output=True)
        commands.append({"tool": Path(argv[0]).name, "exit_code": result.returncode})
        if result.returncode: raise RuntimeError("Steam init bridge build/inspection failed: " + result.stderr[:2000])
        return result.stdout
    original_record = inspect_original(original, original_pin, run)
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
    run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk,
         "-miphoneos-version-min=15.0", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-dynamiclib",
         "-framework", "Foundation", "-Wl,-install_name," + WRAPPER_ID,
         "-Wl,-reexport_library," + str(original), str(ROOT / "compat/steam/SteamInitBridge.m"), "-o", str(wrapper)])
    run(["codesign", "--force", "--sign", "-", str(wrapper)])
    wrapper_record = inspect_wrapper(wrapper, run)
    if source_hashes() != expected_sources: raise ValueError("Steam init bridge sources changed during compilation")
    if inspect_original(original, original_pin, run) != original_record: raise ValueError("Original SDK changed during wrapper compilation")
    return {"schema_version": 1, "status": "built_optional_init_bridge_not_executed", "wrapper": wrapper_record,
            "original": original_record, "original_input": original_pin, "source_hashes": expected_sources, "commands": commands,
            "original_sections_preserved": True, "original_instructions_changed": False,
            "original_other_exports_preserved_by_reexport": True, "sdk_called": False, "authentication_performed": False,
            "scope": "Opt-in packaging; original Init is the sole overridden SDK symbol. Combined coordinator needs a separate explicit runtime launch mode."}


def validate(frameworks, report, original_pin, run=None):
    """Reinspect unsigned staged bytes before signing; never dlopen either SDK."""
    if report.get("schema_version") != 1 or report.get("status") != "built_optional_init_bridge_not_executed" or report.get("original_input") != original_pin:
        raise ValueError("Steam init bridge provenance/input pins differ")
    if report.get("source_hashes") != source_hashes() or report.get("original_sections_preserved") is not True or report.get("original_instructions_changed") is not False or report.get("original_other_exports_preserved_by_reexport") is not True:
        raise ValueError("Steam init bridge source/section/reexport provenance is incomplete or stale")
    if report.get("sdk_called") is not False or report.get("authentication_performed") is not False:
        raise ValueError("Bridge packaging provenance must not claim SDK/authentication execution")
    if not report.get("commands") or any(entry.get("exit_code") != 0 for entry in report["commands"]):
        raise ValueError("Steam init bridge contains missing/failed build commands")
    if run is None:
        env = dict(os.environ)
        def run(argv): return subprocess.check_output(argv, env=env, text=True)
    frameworks = Path(frameworks)
    for name in (ORIGINAL_FILE, WRAPPER_FILE):
        if (frameworks / name).is_symlink() or not (frameworks / name).is_file(): raise ValueError("SDK bridge inputs must be regular staged files")
    if inspect_original(frameworks / ORIGINAL_FILE, original_pin, run) != report.get("original"):
        raise ValueError("Staged unique original SDK differs from bridge build")
    if inspect_wrapper(frameworks / WRAPPER_FILE, run) != report.get("wrapper"):
        raise ValueError("Staged SDK wrapper differs from bridge build")
    return {"original_sections_verified": 12, "original_export_count_verified": SDK_EXPORT_COUNT,
            "wrapper_reexport_verified": ORIGINAL_ID, "sdk_executed": False}
