#!/usr/bin/env python3
"""Reversible ARM64 salary-multiplier cap for the reviewed TFM2 0.7.1 build.

Only caller-selected copies are written. Import patch_all for the complete mod, or patch_game for its salary component.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

BASE = 0x100000000
FUNCTION_VA = 0x1011e7628
FUNCTION_SIZE = 0x2f0
FUNCTION_SHA256 = 'b9b736c1abe33c3608d56bb8b362da28747423a0fcc191b098f9417104c15298'
RETURN_VA = 0x1011e77c8
CAVE_VA = 0x10434dc30
TRAMPOLINE = bytes.fromhex('0190621e0020611e20cc601efd7bc1a8c0035fd6')
ORIGINAL_RETURN = bytes.fromhex('fd7bc1a8')
PATCHED_RETURN = struct.pack('<I', 0x14000000 | (((CAVE_VA - RETURN_VA) // 4) & 0x3ffffff))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def layout(data):
    if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x100000c):
        raise ValueError('Expected thin ARM64 Mach-O')
    count, extent = struct.unpack_from('<II', data, 16)
    if count > 4096 or 32 + extent > len(data):
        raise ValueError('Invalid load commands')
    p, segments, sections, uuid = 32, [], [], None
    for _ in range(count):
        if p + 8 > 32 + extent:
            raise ValueError('Truncated load command')
        cmd, size = struct.unpack_from('<II', data, p)
        if size < 8 or p + size > 32 + extent:
            raise ValueError('Invalid load command')
        if cmd == 0x1b:
            uuid = data[p+8:p+24].hex()
        if cmd == 0x19:
            if size < 72:
                raise ValueError('Truncated segment')
            name = data[p+8:p+24].split(b'\0')[0].decode()
            va, vmsize, offset, filesize, maxprot, prot, ns = struct.unpack_from('<QQQQiiI', data, p+24)
            if 72 + ns * 80 > size or offset + filesize > len(data):
                raise ValueError('Invalid segment extent')
            segments.append(dict(name=name, va=va, size=vmsize, offset=offset, filesize=filesize, prot=prot))
            for i in range(ns):
                s = p + 72 + 80 * i
                sv, ss, so = struct.unpack_from('<QQI', data, s+32)
                sections.append(dict(va=sv, size=ss, offset=so))
        p += size
    if p != 32 + extent or not uuid:
        raise ValueError('Invalid command extent/UUID')
    return uuid, segments, sections


def patch_game(data, reverse=False):
    uuid, segments, sections = layout(data)
    text = [s for s in segments if s['name'] == '__TEXT' and s['va'] == BASE]
    if len(text) != 1 or text[0]['prot'] & 5 != 5:
        raise ValueError('Expected readable/executable __TEXT segment')
    text = text[0]
    def offset(va, size):
        if not text['va'] <= va <= text['va'] + text['filesize'] - size:
            raise ValueError('Patch outside file-backed __TEXT')
        return text['offset'] + va - text['va']
    fn = offset(FUNCTION_VA, FUNCTION_SIZE)
    ret = offset(RETURN_VA, 4)
    cave = offset(CAVE_VA, len(TRAMPOLINE))
    if any(s['va'] < CAVE_VA + len(TRAMPOLINE) and s['va'] + s['size'] > CAVE_VA for s in sections):
        raise ValueError('Cave unexpectedly overlaps a declared section')
    out = bytearray(data)
    expected_ret, replacement_ret = (PATCHED_RETURN, ORIGINAL_RETURN) if reverse else (ORIGINAL_RETURN, PATCHED_RETURN)
    expected_cave, replacement_cave = (TRAMPOLINE, bytes(len(TRAMPOLINE))) if reverse else (bytes(len(TRAMPOLINE)), TRAMPOLINE)
    if out[ret:ret+4] != expected_ret or out[cave:cave+len(TRAMPOLINE)] != expected_cave:
        raise ValueError('Unexpected salary return or cave preimage')
    if reverse:
        out[ret:ret+4] = replacement_ret
        out[cave:cave+len(TRAMPOLINE)] = replacement_cave
    original = bytes(out) if reverse else data
    if sha256(original[fn:fn+FUNCTION_SIZE]) != FUNCTION_SHA256:
        raise ValueError('Unreviewed SalaryBasis::scale_at function')
    # Pin UUID to the reviewed native game; loader header conversions preserve it.
    if uuid != 'd1ee0ffae09c3f5091f7a3ee975c02ae':
        raise ValueError('Unreviewed game UUID')
    if not reverse:
        out[ret:ret+4] = replacement_ret
        out[cave:cave+len(TRAMPOLINE)] = replacement_cave
    report = dict(kind='salary_multiplier_cap', maximum=5.0, minimum=None,
                  uuid=uuid, function_va=hex(FUNCTION_VA), function_sha256=FUNCTION_SHA256,
                  return_va=hex(RETURN_VA), cave_va=hex(CAVE_VA), cave_size=len(TRAMPOLINE),
                  source_sha256=sha256(data), output_sha256=sha256(out), reverse=reverse)
    return bytes(out), report


SPREAD_FUNCTION_VA = 0x101017434
SPREAD_FUNCTION_SIZE = 0x6c4
SPREAD_FUNCTION_SHA256 = 'fdb221b155c119e06bf4f97cbdefaeacc0f538c5bf91054802b90325ef555f0b'
DEFAULT_VA = 0x10434dc50
DEFAULT_BYTES = struct.pack('<dd', 0.23, 0.0)


def adrp(rd, source, target):
    pages = ((target & ~4095) - (source & ~4095)) // 4096
    if not -(1 << 20) <= pages < (1 << 20):
        raise ValueError('ADRP out of range')
    immediate = pages & 0x1fffff
    return 0x90000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5) | rd


def patch_transfer_game(data, reverse=False):
    uuid, segments, sections = layout(data)
    text = [s for s in segments if s['name'] == '__TEXT' and s['va'] == BASE]
    if uuid != 'd1ee0ffae09c3f5091f7a3ee975c02ae' or len(text) != 1 or text[0]['prot'] & 5 != 5:
        raise ValueError('Unreviewed executable game identity')
    text = text[0]
    def offset(va, size):
        if not text['va'] <= va <= text['va'] + text['filesize'] - size:
            raise ValueError('Patch outside executable file-backed __TEXT')
        return text['offset'] + va - text['va']
    if any(s['va'] < DEFAULT_VA + 16 and s['va'] + s['size'] > DEFAULT_VA for s in sections):
        raise ValueError('Spread defaults overlap a declared section')
    patches = [(0x101017820, bytes.fromhex('0068681e'), bytes.fromhex('1f2003d5'), 'remove spread floor')]
    for va in (0x10101778c, 0x1010177a8):
        after = struct.pack('<II', adrp(8, va, DEFAULT_VA), 0x3dc00000 | ((DEFAULT_VA & 4095)//16 << 10) | (8 << 5))
        patches.append((va, bytes.fromhex('081201d000edc23d'), after, 'fallback vector 0.23/0.0'))
    va = 0x101017904
    after = struct.pack('<II', adrp(8, va, DEFAULT_VA), 0xf9400000 | ((DEFAULT_VA & 4095)//8 << 10) | (8 << 5) | 8)
    patches.append((va, bytes.fromhex('e8e703b2c8fde7f2'), after, 'single sample fallback 0.23'))
    patches.append((DEFAULT_VA, bytes(16), DEFAULT_BYTES, 'private fallback constants'))
    out = bytearray(data)
    for va, before, after, label in patches:
        off = offset(va, len(before))
        expected = after if reverse else before
        if out[off:off+len(before)] != expected:
            raise ValueError('Unexpected transfer preimage: ' + label)
        out[off:off+len(before)] = before if reverse else after
    original = bytes(out) if reverse else data
    fn = offset(SPREAD_FUNCTION_VA, SPREAD_FUNCTION_SIZE)
    if sha256(original[fn:fn+SPREAD_FUNCTION_SIZE]) != SPREAD_FUNCTION_SHA256:
        raise ValueError('Unreviewed transfer contest function')
    return bytes(out), dict(kind='transfer_spread_floor_fix', spread_c=0.95, spread_default=0.23,
                           function_va=hex(SPREAD_FUNCTION_VA), function_sha256=SPREAD_FUNCTION_SHA256,
                           source_sha256=sha256(data), output_sha256=sha256(out), reverse=reverse,
                           patches=[dict(va=hex(v),before=b.hex(),after=a.hex(),reason=l) for v,b,a,l in patches])


def patch_all(data, reverse=False):
    # Reverse order keeps each component's preimage independent and reviewable.
    if reverse:
        data, spread = patch_transfer_game(data, True)
        data, salary = patch_game(data, True)
    else:
        data, salary = patch_game(data)
        data, spread = patch_transfer_game(data)
    return data, dict(kind='transfer_and_salary_fix', salary=salary, spread=spread)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--reverse', action='store_true')
    p.add_argument('--report', type=Path)
    args = p.parse_args()
    data, report = patch_all(args.source.read_bytes(), args.reverse)
    with args.output.open('xb') as f:
        f.write(data)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
