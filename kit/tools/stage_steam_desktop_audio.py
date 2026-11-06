#!/usr/bin/env python3
"""Bind only the pinned unsigned-stage Steam client to a static desktop HAL view.

Does not load vendor code or use device APIs. Call before final app signing.
The old embedded ad-hoc signature is deliberately invalidated by metadata edits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "compat/steam/SteamDesktopAudio.c"
FILE = "TFMSteamDesktopAudio.dylib"
TARGET = "@loader_path/" + FILE
INSTALL_NAME = "@rpath/" + FILE
PIN = "9d6c34a96a7dcf0ec425d7a42b82ed4aa9cad2ed977ad622a51c6cec7b5dbc33"
ORIGINAL = "/System/Library/Frameworks/CoreAudio.framework/CoreAudio"
EXPORTS = {"_AudioObjectGetPropertyData", "_AudioObjectGetPropertyDataSize", "_AudioObjectSetPropertyData"}
LOADS = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}
ENV = dict(os.environ)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(argv):
    result = subprocess.run(argv, env=ENV, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("Tool failed: " + Path(argv[0]).name + "\n" + result.stderr[-4000:])
    return result.stdout


def inspect(data):
    if len(data) < 32 or struct.unpack_from("<III", data) != (0xFEEDFACF, 0x100000C, 0):
        raise ValueError("Expected thin ARM64 (not arm64e) Mach-O")
    if struct.unpack_from("<I", data, 12)[0] != 6:
        raise ValueError("Expected MH_DYLIB")
    ncmds, size = struct.unpack_from("<II", data, 16)
    end = 32 + size
    if end > len(data):
        raise ValueError("Load commands outside image")
    offset, dependencies, sections, platform = 32, [], [], None
    for _ in range(ncmds):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        cmd, length = struct.unpack_from("<II", data, offset)
        if length < 8 or length % 8 or offset + length > end:
            raise ValueError("Malformed load command")
        if cmd in LOADS or cmd == 0xD:
            if length < 24:
                raise ValueError("Truncated dylib command")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if not 24 <= name_offset < length:
                raise ValueError("Invalid dylib name offset")
            raw = data[offset + name_offset:offset + length]
            if b"\0" not in raw:
                raise ValueError("Unterminated dylib name")
            name = raw.split(b"\0", 1)[0].decode("utf-8")
            if cmd in LOADS:
                dependencies.append({"name": name, "ordinal": len(dependencies) + 1,
                                     "cmd": cmd, "offset": offset, "size": length, "name_offset": name_offset})
        elif cmd == 0x19:
            if length < 72:
                raise ValueError("Truncated segment")
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + 80 * nsects > length:
                raise ValueError("Section table outside command")
            for index in range(nsects):
                at = offset + 72 + 80 * index
                section_size = struct.unpack_from("<Q", data, at + 40)[0]
                file_offset, flags = struct.unpack_from("<II", data, at + 48)[0], struct.unpack_from("<I", data, at + 64)[0]
                if (flags & 0xFF) in {1, 0xC, 0x12}:  # zero-fill has no bytes in file
                    continue
                if file_offset + section_size > len(data):
                    raise ValueError("Section outside image")
                sections.append({"name": data[at + 16:at + 32].split(b"\0")[0].decode() + "," + data[at:at + 16].split(b"\0")[0].decode(),
                                 "offset": file_offset, "size": section_size,
                                 "sha256": digest(data[file_offset:file_offset + section_size])})
        elif cmd == 0x32:
            platform = struct.unpack_from("<I", data, offset + 8)[0]
        offset += length
    if offset != end or platform != 2:
        raise ValueError("Expected complete iOS-device Mach-O commands")
    return dependencies, sections


def imports(path):
    result = []
    for line in run(["xcrun", "nm", "-m", "-u", str(path)]).splitlines():
        match = re.search(r"external (\S+) \(from ([^)]+)\)", line)
        if match:
            result.append((match[1], match[2]))
    return result


def verify_dyld_hal_bindings(path, provider):
    # dyld_info reads the actual dyld import metadata independently of nm's
    # undefined nlist records; both must agree about all three HAL providers.
    actual = []
    for line in run(["xcrun", "dyld_info", "-imports", str(path)]).splitlines():
        match = re.search(r"(_AudioObject\S+)\s+\(from ([^)]+)\)", line)
        if match:
            actual.append((match[1], match[2]))
    if sorted(actual) != sorted((name, provider) for name in EXPORTS):
        raise ValueError("Actual dyld HAL import bindings differ from reviewed provider")


def stage_audio(frameworks: Path) -> dict:
    frameworks = Path(frameworks).resolve(strict=True)
    client, destination = frameworks / "steamclient.dylib", frameworks / FILE
    if not frameworks.is_dir() or client.is_symlink() or not client.is_file():
        raise ValueError("Need a regular staged steamclient.dylib in Frameworks")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Desktop-audio boundary already exists; use a fresh unsigned stage")
    before = client.read_bytes()
    if digest(before) != PIN:
        raise ValueError("Steam desktop-audio input differs from pinned unsigned stage")
    signature = subprocess.run(["xcrun", "codesign", "-dv", str(client)], env=ENV, text=True, capture_output=True)
    if signature.returncode == 0 and "Signature=adhoc" not in signature.stderr:
        raise ValueError("Refusing to edit an identity-signed Steam client")
    dependencies, sections = inspect(before)
    matches = [item for item in dependencies if item["name"] == ORIGINAL]
    if len(matches) != 1 or matches[0]["cmd"] != 0xC:
        raise ValueError("Expected exactly one ordinary CoreAudio dependency")
    original_imports = imports(client)
    if {name for name, provider in original_imports if provider == "CoreAudio"} != EXPORTS:
        raise ValueError("Steam CoreAudio imports differ from the three reviewed HAL symbols")
    for symbol in EXPORTS:
        if [(name, provider) for name, provider in original_imports if name == symbol] != [(symbol, "CoreAudio")]:
            raise ValueError("Ambiguous HAL symbol provider")
    verify_dyld_hal_bindings(client, "CoreAudio")
    command = matches[0]
    start, end = command["offset"] + command["name_offset"], command["offset"] + command["size"]
    replacement = TARGET.encode() + b"\0"
    if len(replacement) > end - start:
        raise ValueError("New dependency does not fit existing load command")
    after = before[:start] + replacement.ljust(end - start, b"\0") + before[end:]
    after_dependencies, after_sections = inspect(after)
    expected = [dict(item, name=TARGET) if item == command else item for item in dependencies]
    if after_dependencies != expected or after_sections != sections or len(after) != len(before):
        raise ValueError("Metadata rewrite changed sections, ordinals, or unrelated dependencies")
    source_hash = digest(SOURCE.read_bytes())
    with tempfile.TemporaryDirectory(prefix="steam-desktop-audio-") as temporary:
        temporary = Path(temporary)
        output = temporary / FILE
        sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
        run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk,
             "-miphoneos-version-min=15.0", "-std=c11", "-dynamiclib", "-O2", "-Wall", "-Wextra", "-Werror",
             "-Wl,-no_adhoc_codesign", "-Wl,-install_name," + INSTALL_NAME, str(SOURCE), "-o", str(output)])
        built = output.read_bytes()
        built_dependencies, _ = inspect(built)
        if [item["name"] for item in built_dependencies] != ["/usr/lib/libSystem.B.dylib"]:
            raise ValueError("Static Steam HAL must link only libSystem, never CoreAudio/AVFAudio")
        exported = {line.split()[-1] for line in run(["xcrun", "nm", "-gU", str(output)]).splitlines() if line.split()}
        if exported != EXPORTS:
            raise ValueError("Unexpected Steam desktop-audio exports")
        if run(["xcrun", "otool", "-D", str(output)]).splitlines()[1:] != [INSTALL_NAME]:
            raise ValueError("Boundary install name mismatch")
        platform = run(["xcrun", "dyld_info", "-platform", str(output)])
        if not re.search(r"\biOS\b", platform, re.I):
            raise ValueError("dyld_info did not confirm iOS device platform")
        patched = temporary / "steamclient.dylib"
        patched.write_bytes(after)
        after_imports = imports(patched)
        expected_imports = [(name, "TFMSteamDesktopAudio" if provider == "CoreAudio" else provider) for name, provider in original_imports]
        if after_imports != expected_imports:
            raise ValueError("Rebound symbol providers differ from expected ordinal-preserving change")
        verify_dyld_hal_bindings(patched, "TFMSteamDesktopAudio")
        run(["xcrun", "dyld_info", "-platform", str(patched)])
        if source_hash != digest(SOURCE.read_bytes()) or client.read_bytes() != before:
            raise ValueError("Build inputs changed during staging")
        # All checks precede mutations. On local write failure restore the input.
        created_destination, wrote_client = False, False
        try:
            with destination.open("xb") as handle:
                created_destination = True
                handle.write(built)
            wrote_client = True
            client.write_bytes(after)
            if client.read_bytes() != after or destination.read_bytes() != built:
                raise OSError("Staged bytes failed read-back")
        except BaseException:
            if wrote_client:
                client.write_bytes(before)
            if created_destination:
                destination.unlink(missing_ok=True)
            raise
    return {"schema_version": 1, "status": "steam_desktop_hal_unavailable_boundary_staged_requires_signing",
            "client": "steamclient.dylib", "input_sha256": PIN, "output_sha256": digest(after),
            "file": FILE, "sha256": digest(built), "size": len(built), "install_name": INSTALL_NAME,
            "source": "compat/steam/SteamDesktopAudio.c", "source_sha256": source_hash,
            "rebound_dependency": {"from": ORIGINAL, "to": TARGET, "ordinal": command["ordinal"]},
            "changed_metadata_range": {"offset": start, "size": end - start},
            "verified_exports": sorted(EXPORTS), "client_sections": sections,
            "metadata_only": True, "all_sections_preserved": True, "all_other_bytes_preserved": True,
            "instructions_changed": False, "library_ordinals_preserved": True, "game_audio_modified": False,
            "vendor_code_executed": False, "device_accessed": False, "requires_final_signing": True,
            "policy": "Steam desktop HAL devices empty; default IDs unknown; other reads/set unsupported; no native HAL forwarding"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frameworks", type=Path)
    args = parser.parse_args()
    print(json.dumps(stage_audio(args.frameworks), indent=2))
