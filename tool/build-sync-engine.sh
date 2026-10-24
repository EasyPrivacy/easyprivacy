#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
go_bin=${EASYPRIVACY_GO:-go}
cache="$root/.tools/syncthing"
mkdir -p "$cache"
readarray -t upstream < <(python3 - "$root/native/sync-engine/upstream.json" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
for key in ('version','sourceUrl','sourceSha256'): print(value[key])
PY
)
archive="$cache/source-${upstream[0]}.tar.gz"
if [[ ! -f "$archive" ]]; then curl --fail --location --proto '=https' --tlsv1.2 "${upstream[1]}" -o "$archive"; fi
printf '%s  %s\n' "${upstream[2]}" "$archive" | sha256sum --check --status
# The pinned upstream archive is vendored and builds without module downloads.
tar -xzf "$archive" -C "$cache"
targets=("$@")
if [[ ${#targets[@]} == 0 ]]; then targets=(android-arm64); fi
cd "$cache/syncthing"
for target in "${targets[@]}"; do
  mode=(); extra=''
  case "$target" in
    android-arm64) os=android; arch=arm64; mode=(-buildmode=pie); extra='-checklinkname=0'; output="$root/apps/files/android/app/src/main/jniLibs/arm64-v8a/libeasyprivacy_sync_engine.so" ;;
    linux-x64) os=linux; arch=amd64; output="$root/apps/files/native/linux/easyprivacy-sync" ;;
    windows-x64) os=windows; arch=amd64; output="$root/apps/files/native/windows/easyprivacy-sync.exe" ;;
    *) printf 'Unsupported Sync target: %s\n' "$target" >&2; exit 2 ;;
  esac
  mkdir -p "$(dirname "$output")"
  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" "$go_bin" build -p 2 -mod=vendor "${mode[@]}" -trimpath -tags noupgrade \
    -ldflags "-s -w $extra -X github.com/syncthing/syncthing/lib/build.Version=${upstream[0]}" -o "$output" ./cmd/syncthing
  printf '%s\n' "$output"
done
python3 "$root/native/sync-engine/collect-licenses.py" "$cache/syncthing"
