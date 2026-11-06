#!/usr/bin/env python3
"""Private, pinned 1920x1440 UI layout staging. Never writes the Steam installation.

Only pinned ARM64 instructions, explicit __TEXT,__const float32 values, and allowlisted UI properties change. The 2048²
world camera, image dimensions, fonts, and row sizes remain byte-identical.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct

GAME_NAME = 'TeamfightManager2.dylib'
ASSET_NAME = 'bundle.game_data'
DEFAULT_PROFILE = Path(__file__).resolve().parents[1] / 'profiles/ipad-layout-v7.json'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def macho_sections(data):
    if len(data) < 32 or struct.unpack_from('<II', data) != (0xfeedfacf, 0x100000c):
        raise ValueError('Expected a thin ARM64 Mach-O staged game')
    count, size = struct.unpack_from('<II', data, 16)
    if count > 4096 or 32 + size > len(data):
        raise ValueError('Invalid Mach-O command bounds')
    p, result, uuid = 32, [], None
    for _ in range(count):
        if p + 8 > 32 + size:
            raise ValueError('Truncated Mach-O command')
        cmd, n = struct.unpack_from('<II', data, p)
        if n < 8 or p + n > 32 + size:
            raise ValueError('Invalid Mach-O command size')
        if cmd == 0x1b:
            if n != 24:
                raise ValueError('Invalid UUID command')
            uuid = data[p + 8:p + 24].hex()
        if cmd == 0x19:
            if n < 72:
                raise ValueError('Invalid segment')
            ns = struct.unpack_from('<I', data, p + 64)[0]
            if 72 + ns * 80 > n:
                raise ValueError('Invalid section bounds')
            for i in range(ns):
                s = p + 72 + i * 80
                name = data[s:s + 16].split(b'\0')[0].decode('ascii')
                seg = data[s + 16:s + 32].split(b'\0')[0].decode('ascii')
                va, length, offset = struct.unpack_from('<QQI', data, s + 32)
                flags = struct.unpack_from('<I', data, s + 64)[0]
                if flags & 0xff in (1, 12, 18):  # zero-fill sections have no file bytes
                    continue
                if offset + length > len(data):
                    raise ValueError('Section outside file')
                result.append(dict(segment=seg, name=name, va=va, size=length,
                                   offset=offset, sha256=digest(data[offset:offset + length])))
        p += n
    if p != 32 + size or not uuid:
        raise ValueError('Invalid command extent or missing UUID')
    return uuid, result


def patch_game(data, profile, reverse=False):
    uuid, sections = macho_sections(data)
    if uuid != profile['game_uuid']:
        raise ValueError('Unreviewed game UUID; a new layout audit is required')
    result = bytearray(data)
    changes = []
    for patch in profile['native_patches']:
        va = int(patch['va'], 16)
        section = patch.get('section', '__text')
        if patch.get('segment', '__TEXT') != '__TEXT' or section not in ('__text', '__const'):
            raise ValueError('Patch section must be __TEXT,__text or explicit __TEXT,__const float32')
        if section == '__const':
            if patch.get('kind') != 'float32':
                raise ValueError('Constant patches require explicit float32 kind')
            for field in ('before', 'after'):
                raw = bytes.fromhex(patch[field])
                if len(raw) != 4 or not math.isfinite(struct.unpack('<f', raw)[0]):
                    raise ValueError('Constant patch must contain exactly one finite float32')
        elif patch.get('kind', 'instruction') != 'instruction':
            raise ValueError('Code patches require instruction kind')
        matches = [s for s in sections if s['segment'] == '__TEXT' and s['name'] == section
                   and s['va'] <= va < s['va'] + s['size'] - 3]
        if len(matches) != 1:
            raise ValueError('Patch point is not uniquely inside declared __TEXT section')
        offset = matches[0]['offset'] + va - matches[0]['va']
        before, after = bytes.fromhex(patch['before']), bytes.fromhex(patch['after'])
        expected, replacement = (after, before) if reverse else (before, after)
        if len(before) != 4 or len(after) != 4 or result[offset:offset + 4] != expected:
            raise ValueError('Native patch bytes differ at ' + patch['va'])
        result[offset:offset + 4] = replacement
        changes.append(dict(patch, file_offset=offset))
    original = bytes(result) if reverse else data
    _, original_sections = macho_sections(original)
    actual = [{k: s[k] for k in ('segment', 'name', 'va', 'size', 'sha256')} for s in original_sections]
    if actual != profile['original_sections']:
        raise ValueError('Original game sections changed; refusing unreviewed binary')
    return bytes(result), changes


def property_spans(text):
    """Parse this pack's line-oriented UI syntax, retaining all unrelated bytes.

    Every brace scope participates, including style structs; paths distinguish
    repeated node IDs. Unexpected/duplicate properties cannot silently match.
    """
    stack, result, offset = [], {}, 0
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.endswith('{'):
            stack.append(s[:-1].strip())
        elif s == '}':
            if not stack:
                raise ValueError('Unbalanced UI scope')
            stack.pop()
        else:
            m = re.match(r'\s*([A-Za-z_][A-Za-z_0-9]*):\s*([^;\r\n]+);\s*$', line)
            if m and stack:
                key = ('/'.join(stack), m[1])
                if key in result:
                    raise ValueError('Duplicate UI property at ' + repr(key))
                result[key] = (offset + m.start(2), offset + m.end(2), m[2])
        offset += len(line)
    if stack:
        raise ValueError('Unbalanced UI scope')
    return result


def transform_ui(payload, recipe, reverse=False):
    text = payload.decode('utf-8')
    spans = property_spans(text)
    replacements = []
    for change in recipe['properties']:
        key = (change['path'], change['property'])
        if key not in spans:
            raise ValueError('Missing pinned UI property ' + repr(key))
        a, b, current = spans[key]
        expected, new = (change['after'], change['before']) if reverse else (change['before'], change['after'])
        if current != expected:
            raise ValueError('Unexpected pinned UI property ' + repr(key))
        replacements.append((a, b, new))
    for a, b, new in sorted(replacements, reverse=True):
        text = text[:a] + new + text[b:]
    result = text.encode('utf-8')
    original = result if reverse else payload
    if digest(original) != recipe['sha256']:
        raise ValueError('Original UI asset differs from reviewed hash')
    return result


def process_pack(source, profile, output=None, reverse=False):
    """Stream untouched records; reverse reconstructs and hashes exact source pack."""
    recipes = {r['name']: r for r in profile['assets']}
    seen, changed, total_hash = set(), [], hashlib.sha256()
    writer = Path(output).open('xb') if output else None
    def emit(chunk):
        total_hash.update(chunk)
        if writer:
            writer.write(chunk)
    try:
        with Path(source).open('rb') as f:
            length = Path(source).stat().st_size
            def read(n):
                if n < 0 or f.tell() + n > length:
                    raise ValueError('Truncated asset pack')
                data = f.read(n)
                if len(data) != n:
                    raise ValueError('Truncated asset pack')
                return data
            def string(limit):
                n = struct.unpack('<I', read(4))[0]
                if not 0 < n <= limit:
                    raise ValueError('Invalid asset string length')
                raw = read(n)
                return raw.decode('utf-8'), struct.pack('<I', n) + raw
            count_raw = read(4)
            count = struct.unpack('<I', count_raw)[0]
            if not 0 < count <= 10000:
                raise ValueError('Invalid asset count')
            emit(count_raw)
            for _ in range(count):
                kind, kh = string(64)
                name, nh = string(4096)
                if name in seen:
                    raise ValueError('Duplicate asset name')
                seen.add(name)
                n = struct.unpack('<I', read(4))[0]
                if f.tell() + n > length:
                    raise ValueError('Asset length exceeds pack')
                emit(kh + nh)
                if name in recipes:
                    if kind != 'ui' or n > 4 * 1024 * 1024:
                        raise ValueError('Pinned layout is not a bounded UI record')
                    payload = read(n)
                    result = transform_ui(payload, recipes[name], reverse)
                    emit(struct.pack('<I', len(result)))
                    emit(result)
                    changed.append(dict(name=name, input_sha256=digest(payload),
                                        output_sha256=digest(result), properties=recipes[name]['properties']))
                else:
                    emit(struct.pack('<I', n))
                    remaining = n
                    while remaining:
                        chunk = read(min(remaining, 1024 * 1024))
                        emit(chunk)
                        remaining -= len(chunk)
            if f.tell() != length or set(recipes) - seen:
                raise ValueError('Trailing pack bytes or missing pinned assets')
        value = total_hash.hexdigest()
        if reverse and value != profile['original_assets_sha256']:
            raise ValueError('Restored pack does not match original pinned asset hash')
        return value, changed, count
    finally:
        if writer:
            writer.close()


def stage(game, assets, profile_path, output):
    game, assets, output = Path(game).resolve(strict=True), Path(assets).resolve(strict=True), Path(output).resolve()
    profile_path = Path(profile_path).resolve(strict=True)
    profile = json.loads(profile_path.read_text())
    input_bundles = [p for source in (game, assets) for p in source.parents if p.suffix == '.app']
    if output.exists() or output in game.parents or output in assets.parents or any(p in output.parents for p in input_bundles):
        raise ValueError('Layout output must be a fresh separate private directory')
    if file_hash(assets) != profile['original_assets_sha256']:
        raise ValueError('Unreviewed assets; a new layout audit is required')
    before = game.read_bytes()
    after, changes = patch_game(before, profile)
    output.mkdir(parents=True)
    (output / 'INCOMPLETE').write_text('Layout staging incomplete\n')
    (output / GAME_NAME).write_bytes(after)
    asset_hash, records, count = process_pack(assets, profile, output / ASSET_NAME)
    report = dict(schema=1, status='staged_not_device_validated', profile_sha256=file_hash(profile_path),
                  profile_id=profile['id'], virtual_canvas=profile['virtual_canvas'],
                  game=dict(input_sha256=digest(before), output_sha256=digest(after), native_patches=changes),
                  assets=dict(input_sha256=profile['original_assets_sha256'], output_sha256=asset_hash,
                              records=count, changed=records),
                  limitations=profile['limitations'])
    (output / 'layout-stage.json').write_text(json.dumps(report, indent=2) + '\n')
    validate(output, profile_path, digest(before), profile['original_assets_sha256'])
    (output / 'INCOMPLETE').unlink()
    return report


def validate(directory, profile_path=DEFAULT_PROFILE, expected_original_game_sha256=None,
             expected_original_assets_sha256=None):
    """Independently undo changes, verify pinned sections/assets and loader hash.

    Caller supplies original loader/asset-stage hashes from its existing trusted
    pipeline. Post-hashes and this report alone are never the security boundary.
    Directory may be a standalone layout stage or an assembled .app bundle.
    """
    directory, profile_path = Path(directory), Path(profile_path)
    profile = json.loads(profile_path.read_text())
    report = json.loads((directory / 'layout-stage.json').read_text())
    game = directory / 'Frameworks' / GAME_NAME if (directory / 'Frameworks').is_dir() else directory / GAME_NAME
    if not expected_original_game_sha256 or not expected_original_assets_sha256:
        raise ValueError('Independent original game/asset hashes are required')
    if expected_original_assets_sha256 != profile['original_assets_sha256']:
        raise ValueError('Asset-stage original hash differs from pinned layout profile')
    if (report.get('schema') != 1 or report.get('status') != 'staged_not_device_validated'
            or report.get('profile_id') != profile['id'] or report.get('virtual_canvas') != profile['virtual_canvas']
            or report.get('profile_sha256') != file_hash(profile_path)):
        raise ValueError('Layout report profile differs')
    restored, changes = patch_game(game.read_bytes(), profile, reverse=True)
    if report['game'].get('native_patches') != changes:
        raise ValueError('Native patch provenance differs')
    if digest(restored) != expected_original_game_sha256 or report['game']['input_sha256'] != expected_original_game_sha256:
        raise ValueError('Restored game differs from original loader-stage hash')
    if file_hash(game) != report['game']['output_sha256']:
        raise ValueError('Layout game post hash differs')
    restored_assets, reversed_records, count = process_pack(directory / ASSET_NAME, profile, reverse=True)
    expected_records = [dict(r, input_sha256=r['output_sha256'], output_sha256=r['input_sha256']) for r in reversed_records]
    if report['assets'].get('changed') != expected_records or report['assets'].get('input_sha256') != expected_original_assets_sha256:
        raise ValueError('Asset transform provenance differs')
    if restored_assets != expected_original_assets_sha256 or count != report['assets']['records']:
        raise ValueError('Restored asset pack differs from original asset-stage hash')
    if file_hash(directory / ASSET_NAME) != report['assets']['output_sha256']:
        raise ValueError('Layout asset post hash differs')
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game', type=Path, required=True)
    p.add_argument('--assets', type=Path, required=True)
    p.add_argument('--profile', type=Path, default=DEFAULT_PROFILE)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    try:
        result = stage(args.game, args.assets, args.profile, args.output)
    except (ValueError, OSError, KeyError, UnicodeError, struct.error) as e:
        p.error(str(e))
    print(json.dumps(dict(status=result['status'], output=str(args.output),
                          native_patches=len(result['game']['native_patches']), changed_assets=len(result['assets']['changed']))))


if __name__ == '__main__':
    main()
