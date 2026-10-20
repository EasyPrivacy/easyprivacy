#!/usr/bin/env python3
"""Collect exact pinned Rust dependency notices from Cargo's downloaded sources."""
from pathlib import Path
import argparse
import tomllib

parser = argparse.ArgumentParser()
parser.add_argument('--cargo-home', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent
lock = tomllib.loads((root / 'Cargo.lock').read_text())
parts = ['EasyPrivacy native pairing: third-party notices\n'
         'Pinned Rust dependencies, including build-time dependencies.\n'
         'RustCrypto SPAKE2 is used under its MIT license. Other license texts\n'
         'are retained below as provided in the corresponding source archives.\n']
for package in lock['package']:
    if 'source' not in package:
        continue
    name = f"{package['name']}-{package['version']}"
    source = next((args.cargo_home / 'registry/src').glob('*/' + name))
    licenses = sorted(p for p in source.iterdir() if p.is_file()
                      and p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')))
    if not licenses:
        raise RuntimeError(f'No license file found for {name}')
    for license_file in licenses:
        parts.append(f"\n{'=' * 72}\n{name} / {license_file.name}\n{'=' * 72}\n")
        parts.append(license_file.read_text(errors='strict'))
(root / 'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(parts), encoding='utf-8')
app_copy = root.parents[1] / 'app/assets/native-licenses.txt'
app_copy.write_bytes((root / 'THIRD-PARTY-NOTICES.txt').read_bytes())
print(f'Collected notices for {len(lock["package"]) - 1} pinned dependencies.')
