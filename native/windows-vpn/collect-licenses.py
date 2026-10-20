#!/usr/bin/env python3
"""Collect notices from the pinned Go module graph for bundled Windows code."""
import json
import os
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parent
text=subprocess.check_output([os.environ.get('EASYPRIVACY_GO','go'),'list','-m','-json','all'],cwd=root,text=True)
decoder=json.JSONDecoder();modules=[]
while text.strip():
    text=text.lstrip();item,offset=decoder.raw_decode(text);modules.append(item);text=text[offset:]
notices=['EasyPrivacy embedded Windows VPN dependencies\n']
for item in modules:
    effective=item.get('Replace',item)
    if 'Dir' not in effective or item.get('Main'):continue
    directory=Path(effective['Dir']);files=[p for p in directory.iterdir() if p.is_file() and p.name.upper() in ('LICENSE','LICENSE.TXT','LICENSE.MD','COPYING','NOTICE')]
    if not files:raise RuntimeError(f"No license found for {item['Path']}")
    notices.append(f"\n{'='*72}\n{item['Path']} {effective.get('Version','')}\n")
    notices.extend(p.read_text(encoding='utf-8',errors='replace')+'\n' for p in files)
notices.append('\nWireGuardNT SDK 1.1\n'+(root/'WIREGUARDNT-LICENSE.txt').read_text())
goroot=Path(subprocess.check_output([os.environ.get('EASYPRIVACY_GO','go'),'env','GOROOT'],text=True).strip())
notices.append('\nGo standard library\n'+(goroot/'LICENSE').read_text())
(root/'THIRD-PARTY-NOTICES.txt').write_text(''.join(notices),encoding='utf-8')
print(f'Collected license notices from {len(modules)-1} Go dependency modules.')
