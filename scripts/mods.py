#!/usr/bin/env python3
"""Compile optional iPad mods privately using the SDK that ships with the purchased game."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'kit'
SHEET = 'asset/base/setting/champion_info'
SHEET_SHA = '3bbc9632c4be785c8c4cda2ce49f7d75d91cdae923b1d3765b93b10fe66ef764'


def champion_sheet(path):
    with path.open('rb') as f:
        def number():
            return struct.unpack('<I', f.read(4))[0]

        def label():
            length = number()
            if length > 8192:
                raise ValueError('Unexpected record name')
            return f.read(length).decode()

        for _ in range(number()):
            kind, key, length = label(), label(), number()
            if kind == 'champion_info_sheet' and key == SHEET:
                if length > 2_000_000:
                    break
                raw = f.read(length)
                if hashlib.sha256(raw).hexdigest() != SHEET_SHA:
                    break
                data = json.loads(raw)
                data.update({item['id']: item for item in data.pop('mod_champions')})
                return dict(sorted(data.items()))
            f.seek(length, 1)
    raise ValueError('Unsupported champion sheet. Check the purchased game version.')


def make_tables(directory, sheet):
    fields = ['attack', 'magic_power', 'hp', 'defence', 'magic_resistance', 'move_speed']
    stats = {}
    actions = {}
    lines = ['fn baseline(id: &str) -> Option<[f64; 3]> { Some(match id {']
    for name, champion in sheet.items():
        if not re.fullmatch('[a-z_]+', name):
            raise ValueError('Unexpected champion id')
        stats[name] = {group: [champion[group][field] for field in fields] for group in ('stat', 'growth')}
        attack = champion.get('attack', {})
        actions[name] = {field: attack.get(field, 0) for field in ('cooltime', 'range')}
        if attack:
            values = (float(attack['cooltime']), attack['range'] / 1000, attack.get('growth_range', 0) / 1000)
            lines.append(f'    "{name}" => [{values[0]!r}, {values[1]!r}, {values[2]!r}],')
    lines.extend(['    _ => return None,', '}) }'])
    (directory / 'views/src/extra_baseline.rs').write_text('\n'.join(lines) + '\n')
    base = dict(schema=1, asset=SHEET, payload_sha256=SHEET_SHA, reference_level=6.5,
                growth_steps=5.5, fields=fields, champions=stats)
    (directory / 'views/src/base-champions.json').write_text(json.dumps(base))
    (directory / 'management/src/champion-actions.json').write_text(json.dumps(actions))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', required=True, type=Path, help='Purchased macOS TeamfightManager2.app')
    p.add_argument('--base', required=True, type=Path, help='Completed unsigned build directory (contains rebuild-report.json)')
    p.add_argument('--postmatch-dll', type=Path, help='Optional original match review release DLL (4.0.0-beta.14)')
    p.add_argument('--illustrations', type=Path, help='Optional original illustration archive; also requires Pillow')
    p.add_argument('--salary', action='store_true', help='Apply reviewed salary/transfer balance patches')
    p.add_argument('--offline', action='store_true', help='Use only already cached Rust crates')
    args = p.parse_args()
    if args.illustrations and not importlib.util.find_spec("PIL"):
        p.error("Illustrations require Pillow in this Python environment. See docs/mods.md.")
    sys.path.insert(0, str(KIT / 'tools'))
    from rebuild_personal_app import check_inputs
    report, _ = check_inputs(args.app, KIT / 'profiles/local-inputs-v2.json')
    if report['local_source_changed']:
        p.error(f"Unsupported Steam input: {report['changed']}")
    base = args.base.resolve(strict=True)
    if not (base / 'rebuild-report.json').is_file():
        p.error('--base must be the completed base build directory')
    macos = args.app.resolve() / 'Contents/MacOS'
    sdk = macos / 'mod-sdk-stable/mod-api-stable'
    if not (sdk / 'Cargo.toml').is_file():
        p.error('Install the macOS Steam game with the bundled stable mod SDK')
    for tool in ('cargo', 'rustc'):
        if not shutil.which(tool):
            p.error('Install Rust 1.95.0 and its aarch64-apple-ios target (docs/mods.md)')
    rustc = os.environ.get('RUSTC', 'rustc')
    if subprocess.check_output([rustc, '--version'], text=True).split()[1] != '1.95.0':
        p.error('Use Rust 1.95.0 (see docs/mods.md)')
    work = ROOT / 'work'
    work.mkdir(exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='mods-', dir=work))
    names = ['views', 'management', 'training']
    if args.postmatch_dll:
        names.append('postmatch')
    for name in names:
        shutil.copytree(KIT / 'community' / name, out / name)
    (out / 'mod-api-stable').symlink_to(sdk, target_is_directory=True)
    make_tables(out, champion_sheet(macos / 'bundle.game_data'))
    from facility_inputs import generate_facility_inputs
    generate_facility_inputs(macos / 'bundle.game_data', out / 'management')
    if args.postmatch_dll:
        subprocess.run([sys.executable, out / 'postmatch/extract-comments.py',
                        args.postmatch_dll, out / 'postmatch/comments.tsv'], check=True)
    pkg = [sys.executable, KIT / 'tools/package_community_mods.py', '--base', base,
           '--output', out / 'package', '--version', '12', '--steam-runtime-fixes']
    if args.salary:
        pkg.append('--salary')
    env = {**os.environ, 'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
           'CARGO_TARGET_DIR': str(out / 'target')}
    for name in names:
        crate = out / name
        info = crate / 'mod.mod_info'
        mod_id = json.loads(info.read_text())['mod_id']
        cmd = ['cargo', 'build', '--locked', '--manifest-path', crate / 'Cargo.toml', '--release',
               '--target', 'aarch64-apple-ios']
        if args.offline:
            cmd.append('--offline')
        subprocess.run(cmd, check=True, env=env)
        pkg.extend(['--native', info, out / f'target/aarch64-apple-ios/release/lib{mod_id}.dylib'])
    if args.illustrations:
        subprocess.run([sys.executable, KIT / 'tools/stage_banpick_art.py', args.illustrations, out / 'art'], check=True)
        pkg.extend(['--data', 'tfm2_view_plus_ios', out / 'art'])
    subprocess.run(pkg, check=True)
    print(f'Unsigned modded app: {out}/package/TFM2Probe.app')


if __name__ == '__main__':
    main()
