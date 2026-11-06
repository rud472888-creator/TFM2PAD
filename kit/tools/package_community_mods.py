#!/usr/bin/env python3
"""Extend a freshly validated, unsigned iPad build with local iOS mod libraries before signing."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / "community" / "salary"))
from patch_salary import patch_all


def digest(path):
    with path.open("rb") as source:
        import hashlib
        return hashlib.file_digest(source, "sha256").hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def read_module(info_path, binary):
    info = json.loads(info_path.read_text())
    ident = info["mod_id"]
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", ident):
        raise ValueError("Invalid module id")
    if not info.get("contains_code") or not binary.is_file() or binary.is_symlink():
        raise ValueError(f"Expected native library for {ident}")
    def inspect(*args):
        return subprocess.check_output(["xcrun", *args, str(binary)], text=True)
    platform = inspect("vtool", "-show-build")
    device_target = re.search(r"platform\s+IOS\b|cmd LC_VERSION_MIN_IPHONEOS\b", platform)
    if inspect("lipo", "-archs").strip() != "arm64" or not device_target:
        raise ValueError(f"Expected physical iOS arm64 Mach-O for {ident}")
    if not re.search(r"^\s*iOS\s+[0-9]", inspect("dyld_info","-platform"), re.MULTILINE):
        raise ValueError(f"Apple dyld rejected native library for {ident}")
    if "_tfm2_mod_entry_stable" not in inspect("nm", "-gU").split():
        raise ValueError(f"Missing stable mod entry for {ident}")
    return ident


def stage(args):
    base = args.base.resolve(strict=True)
    report = json.loads((base / "rebuild-report.json").read_text())
    source = base / "TFM2Probe.app"
    if (base / "INCOMPLETE").exists() or report["status"] != "rebuilt_unsigned_not_runtime_validated" or report["signed"]:
        raise ValueError("A complete unsigned base rebuild is required")
    if Path(report["bundle"]).resolve() != source or (source / "TFMCommunityMods").exists():
        raise ValueError("Unexpected base bundle")
    plist = plistlib.loads((source / "Info.plist").read_bytes())
    host = json.loads((source / "probe-build.json").read_text())
    if digest(source / "TFM2Probe") != host["executable_sha256_before_signing"] or "probe/CommunityMods.m" not in host["source_sha256"]:
        raise ValueError("Verified mod-capable host required")
    if plist.get("TFMPersonalLaunchMode") != "steam-online" or int(plist["CFBundleVersion"]) >= args.version:
        raise ValueError("Expected Steam online base and newer build number")
    layout = json.loads((source / "layout-stage.json").read_text())
    profiles = [KIT / "profiles" / f"ipad-layout-v{version}.json" for version in (5, 6, 7)]
    reviewed = {json.loads(p.read_text())["id"]: digest(p) for p in profiles if p.is_file()}
    if reviewed.get(layout["profile_id"]) != layout["profile_sha256"]:
        raise ValueError("Unreviewed base layout or game build")
    game_rel = Path("Frameworks/TeamfightManager2.dylib")
    if digest(source / game_rel) != layout["game"]["output_sha256"] or digest(source / "bundle.game_data") != layout["assets"]["output_sha256"]:
        raise ValueError("Base image or asset hash changed")
    native = {read_module(meta, lib): (meta, lib) for meta,lib in args.native}
    if len(native) != len(args.native):
        raise ValueError("Duplicate native mod id")
    if not native:
        raise ValueError("At least one native mod required")
    output = args.output.resolve()
    if output == base or base in output.parents or output in base.parents:
        raise ValueError("Keep base and output separate")
    output.mkdir(exist_ok=False)
    incomplete = output / "INCOMPLETE"
    incomplete.write_text("Unfinished community package\n")
    bundle = output / source.name
    subprocess.run(["cp","-cR",str(source),str(bundle)],check=True)
    mods = bundle / "TFMCommunityMods"
    mods.mkdir()
    plugins = {}
    for ident,(meta,library) in native.items():
        dest = mods / ident
        dest.mkdir()
        shutil.copyfile(meta, dest / "mod.mod_info")
        lib_dest = bundle / "Frameworks" / (ident + ".dylib")
        if lib_dest.exists():
            raise ValueError("Library name collision")
        input_hash = digest(library)
        shutil.copyfile(library,lib_dest)
        if digest(lib_dest) != input_hash:
            raise ValueError("Native input changed during staging")
        subprocess.run(["xcrun","install_name_tool","-id","@rpath/" + lib_dest.name,str(lib_dest)],check=True)
        plugins[ident] = {"metadata_sha256":digest(dest / "mod.mod_info"), "input_library_sha256":input_hash,
                          "library_sha256_before_signing":digest(lib_dest)}
    for ident, folder in args.data:
        if ident not in plugins:
            raise ValueError("Resources require a matching native module")
        resource_hash = sha256()
        count = 0
        for src in sorted(Path(folder).rglob("*")):
            dst = mods / ident / src.relative_to(folder)
            if src.is_symlink() or dst.exists():
                raise ValueError("Resource collision or symlink")
            if src.is_dir():
                dst.mkdir()
                continue
            if not stat.S_ISREG(src.stat().st_mode) or src.suffix.lower() not in {".png",".ui",".i18n",".json",".override_info",".skin_index"}:
                raise ValueError(f"Unexpected resource: {src.name}")
            shutil.copyfile(src,dst)
            resource_hash.update(str(src.relative_to(folder)).encode() + b"\0" + bytes.fromhex(digest(dst)))
            count += 1
        plugins[ident]["resource_file_count"] = count
        plugins[ident]["resource_digest"] = resource_hash.hexdigest()
    patch = None
    if args.salary:
        game = bundle / game_rel
        original = game.read_bytes()
        changed, patch = patch_all(original)
        restored, _ = patch_all(changed,reverse=True)
        if restored != original:
            raise ValueError("Salary patch failed reversal to verified 4:3/Steam image")
        game.write_bytes(changed)
    plist["CFBundleVersion"] = str(args.version)
    (bundle / "Info.plist").write_bytes(plistlib.dumps(plist))
    launch_path = bundle / "personal-launch.json"
    launch = json.loads(launch_path.read_text())
    launch["info_plist_sha256_before_signing"] = digest(bundle / "Info.plist")
    write_json(launch_path,launch)
    result = {"stage":"unsigned","version":args.version,"base_report_sha256":digest(base/"rebuild-report.json"),
              "base_layout_sha256":digest(bundle/"layout-stage.json"),"modules":plugins,"salary":patch}
    from steam_runtime_fixes import stage_or_verify
    result["steam_runtime_fixes"] = stage_or_verify(bundle)
    write_json(bundle / "community-stage.json", result)
    incomplete.unlink()
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--native", type=Path, nargs=2, action="append", default=[], metavar=("MOD_INFO","IOS_DYLIB"))
    parser.add_argument("--data", nargs=2, action="append", default=[], metavar=("MOD_ID","RESOURCE_DIR"))
    parser.add_argument("--salary", action="store_true")
    parser.add_argument("--steam-runtime-fixes", action="store_true", help="Explicitly request the Steam stability fixes (already mandatory for the personal game)")
    options = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR","/Applications/Xcode.app/Contents/Developer")
    print(json.dumps(stage(options),ensure_ascii=False,indent=2))
