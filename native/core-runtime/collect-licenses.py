#!/usr/bin/env python3
"""Collect licenses from the pinned private-runtime module graph."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
go = os.environ.get('EASYPRIVACY_GO', 'go')
text = subprocess.check_output([go, 'list', '-m', '-json', 'all'], cwd=root, text=True)
decoder = json.JSONDecoder()
notices = ['EasyPrivacy private connection runtime dependencies\n']
while text.strip():
    item, offset = decoder.raw_decode(text.lstrip())
    text = text.lstrip()[offset:]
    effective = item.get('Replace', item)
    if item.get('Main') or 'Dir' not in effective:
        continue
    files = [p for p in Path(effective['Dir']).iterdir() if p.is_file()
             and p.name.upper() in ('LICENSE', 'LICENSE.TXT', 'LICENSE.MD', 'COPYING', 'NOTICE')]
    if not files:
        raise RuntimeError('Missing license: ' + item['Path'])
    notices.append('\n' + '=' * 72 + '\n' + item['Path'] + ' ' + effective.get('Version', '') + '\n')
    notices.extend(p.read_text(encoding='utf-8', errors='replace') + '\n' for p in files)
goroot = Path(subprocess.check_output([go, 'env', 'GOROOT'], text=True).strip())
notices.append('\nGo standard library\n' + (goroot / 'LICENSE').read_text())
result = ''.join(notices)
(root / 'THIRD-PARTY-NOTICES.txt').write_text(result, encoding='utf-8')
asset = root.parents[1] / 'apps/core/assets/native-licenses.txt'
marker = '\n\nEasyPrivacy private connection runtime dependencies\n'
original = asset.read_text(encoding='utf-8').split(marker)[0]
asset.write_text(original.rstrip() + '\n\n' + result, encoding='utf-8')
