#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
sdk="$root/.tools/wireguard"
mkdir -p "$sdk" "$root/native/windows-vpn/runtime" "$root/app/native/windows"
archive="$sdk/wireguard-nt-1.1.zip"
[[ -f "$archive" ]] || curl --fail --location --proto '=https' --tlsv1.3 https://download.wireguard.com/wireguard-nt/wireguard-nt-1.1.zip -o "$archive"
python3 - "$archive" "$root" <<'PY'
import hashlib,sys,zipfile
from pathlib import Path
archive,root=Path(sys.argv[1]),Path(sys.argv[2])
with zipfile.ZipFile(archive) as package:
    dll=package.read('wireguard-nt/bin/amd64/wireguard.dll')
    assert hashlib.sha256(dll).hexdigest()=='b1b85e072c45d81358be29d94c599dc76652f912be8c0f0a41e2d5d89a6461d3','WireGuardNT driver hash mismatch'
    (root/'native/windows-vpn/runtime/wireguard.dll').write_bytes(dll)
    (root/'native/windows-vpn/WIREGUARDNT-LICENSE.txt').write_bytes(package.read('wireguard-nt/LICENSE.txt'))
PY
cd "$root/native/windows-vpn"
go_bin=${EASYPRIVACY_GO:-go}
"$go_bin" test ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 "$go_bin" build -mod=readonly -trimpath -ldflags='-H=windowsgui' -o "$root/app/native/windows/easyprivacy-vpn.exe" .
EASYPRIVACY_GO="$go_bin" python3 collect-licenses.py
