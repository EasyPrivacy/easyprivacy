#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
arch=${1:-amd64}
case "$arch" in
    amd64) target=x86_64-unknown-linux-gnu ;;
    arm64) target=aarch64-unknown-linux-gnu; export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=${CC:-aarch64-linux-gnu-gcc} ;;
    *) exit 2 ;;
esac
cargo_bin=${EASYPRIVACY_CARGO:-cargo}
"$cargo_bin" build --locked --manifest-path "$root/native/pairing/Cargo.toml" --target "$target" --release
