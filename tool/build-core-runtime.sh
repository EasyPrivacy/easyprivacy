#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
go_bin=${EASYPRIVACY_GO:-go}
cd "$root/native/core-runtime"
targets=("$@")
if [[ ${#targets[@]} == 0 ]]; then targets=(android-arm64 windows-x64 linux-x64); fi
for target in "${targets[@]}"; do
  mode=()
  case "$target" in
    android-arm64) os=android; arch=arm64; mode=(-buildmode=pie); output="$root/apps/core/android/app/src/main/jniLibs/arm64-v8a/libeasyprivacy_core_runtime.so" ;;
    android-arm) os=android; arch=arm; mode=(-buildmode=pie); output="$root/apps/core/android/app/src/main/jniLibs/armeabi-v7a/libeasyprivacy_core_runtime.so" ;;
    android-x64) os=android; arch=amd64; mode=(-buildmode=pie); output="$root/apps/core/android/app/src/main/jniLibs/x86_64/libeasyprivacy_core_runtime.so" ;;
    windows-x64) os=windows; arch=amd64; output="$root/apps/core/native/windows/easyprivacy-core-runtime.exe" ;;
    linux-x64) os=linux; arch=amd64; output="$root/apps/core/native/linux/easyprivacy-core-runtime" ;;
    linux-arm64) os=linux; arch=arm64; output="$root/apps/core/native/linux/easyprivacy-core-runtime" ;;
    *) printf 'Unsupported runtime target: %s\n' "$target" >&2; exit 2 ;;
  esac
  mkdir -p "$(dirname "$output")"
  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" "$go_bin" build "${mode[@]}" -trimpath -ldflags '-s -w' -o "$output" ./cmd/core-runtime
  chmod 0755 "$output"
  printf '%s\n' "$output"
done
EASYPRIVACY_GO="$go_bin" python3 collect-licenses.py
