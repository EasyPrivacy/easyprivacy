#!/usr/bin/env python3
"""Preserve upstream and vendored dependency notices with the unmodified engine."""
import json
from pathlib import Path
import re
import sys
import os
import subprocess

source=Path(sys.argv[1]).resolve()
root=Path(__file__).resolve().parents[2]
manifest=json.loads((root/'native/sync-engine/upstream.json').read_text())
parts=[f'Syncthing {manifest["version"]}\nSource: {manifest["sourceUrl"]}\n'
       f'Source SHA-256: {manifest["sourceSha256"]}\n'
       'The engine is unmodified upstream source. EasyPrivacy supplies its process/connection wrapper.\n\n',
       (source/'LICENSE').read_text(), '\n'+(source/'AUTHORS').read_text()+'\n']
go_root = Path(subprocess.check_output([os.environ.get('EASYPRIVACY_GO', 'go'), 'env', 'GOROOT'], text=True).strip())
parts.extend(['\nGo runtime LICENSE\n', (go_root/'LICENSE').read_text()])
for path in sorted((source/'vendor').rglob('*')):
    if path.is_file() and re.match(r'^(LICENSE|COPYING|NOTICE)([.-].*)?$',path.name,re.I):
        parts.extend(['\n'+'='*72+'\n'+str(path.relative_to(source))+'\n',path.read_text(errors='replace')])
output=root/'apps/files/assets/sync-engine-licenses.txt'
output.parent.mkdir(exist_ok=True)
output.write_text('\n'.join(line.rstrip() for line in '\n'.join(parts).splitlines())+'\n',encoding='utf-8')
