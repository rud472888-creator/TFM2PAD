#!/usr/bin/env python3
"""Copy the user's pinned game data into a private diagnostic app. No execution."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import portkit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--profile', required=True, type=Path)
    parser.add_argument('--probe-app', required=True, type=Path)
    args = parser.parse_args()
    source, target = args.app.resolve(strict=True), args.probe_app.resolve(strict=True)
    portkit.require_outside_source(target, source)
    if plistlib.loads((target / 'Info.plist').read_bytes()).get('CFBundleIdentifier') != 'org.tfm2pad.staging':
        parser.error('Expected private diagnostic app bundle')
    profile = json.loads(args.profile.read_text())
    current = portkit.observe(source)
    staged = json.loads((target / 'loader-stage.json').read_text())
    if portkit.differences(profile, current) or portkit.differences(staged['original_inputs'], current):
        parser.error('Source or staged game differs from pinned inputs')
    if (target / 'LoaderStageIncomplete').exists():
        parser.error('Game loader staging is incomplete')
    destination = target / 'bundle.game_data'
    marker = target / 'AssetStageIncomplete'
    if destination.exists() or destination.is_symlink() or marker.exists() or (target / 'asset-stage.json').exists():
        parser.error('Assets already exist or prior staging is incomplete; use a fresh bundle')
    _, files = portkit.source_files(source)
    marker.write_text('Asset staging incomplete; do not sign or launch.\n')
    shutil.copyfile(files['data'], destination)
    expected = current['files']['data']
    if destination.stat().st_size != expected['size'] or portkit.sha256(destination) != expected['sha256']:
        parser.error('Copied data differs from pinned source; incomplete marker retained')
    if portkit.differences(current, portkit.observe(source)):
        parser.error('Original input changed during copying; incomplete marker retained')
    (target / 'asset-stage.json').write_text(json.dumps({
        'status': 'copied_and_hash_verified_not_runtime_validated',
        'app_id': portkit.APP_ID, 'steam_build_id': current['steam_build_id'],
        'source': expected, 'destination': 'bundle.game_data',
        'game_sha256': current['files']['game']['sha256'],
        'limitations': ['Private purchased game data; do not redistribute',
                        'Resource lookup and save paths require actual game validation',
                        'Re-sign the app after staging; no install or game execution performed']
    }, indent=2) + '\n')
    marker.unlink()
    print('Pinned personal game data copied and verified. Keep app private and re-sign before installation.')


if __name__ == '__main__':
    main()
