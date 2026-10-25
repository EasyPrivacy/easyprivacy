#!/usr/bin/env bash
# Runs a prebuilt native-runtime test under temporary systemd restrictions.
# Build from core/: go test -c -o ../.tools/drive-runtime-sandbox.test github.com/easyprivacy/easyprivacy/core-runtime
# Run as root: bash core/scripts/test-drive-sandbox.sh .tools/drive-runtime-sandbox.test
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run this sandbox check as root.' >&2; exit 2; }
binary=$(realpath -- "${1:?Specify the compiled native-runtime test binary}")
unit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../packaging" && pwd)/easyprivacy-drive.service
[[ -x "$binary" ]] || { echo 'The test binary is not executable.' >&2; exit 2; }

# Apply the actual non-path sandbox properties. Use the existing nobody account
# instead of installing the production service account or touching cloud data.
properties=()
families=
while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in
        UMask=*|NoNewPrivileges=*|PrivateTmp=*|PrivateDevices=*|ProtectSystem=*|ProtectKernelTunables=*|ProtectKernelModules=*|ProtectControlGroups=*|RestrictSUIDSGID=*|LockPersonality=*|MemoryDenyWriteExecute=*|CapabilityBoundingSet=*)
            properties+=(--property="$line") ;;
        RestrictAddressFamilies=*) families=${line#*=} ;;
    esac
done < "$unit"
[[ -n "$families" && ${#properties[@]} -ge 10 ]] || { echo 'Incomplete Drive sandbox configuration.' >&2; exit 2; }
test_args=(-test.run='^TestBridgeTransferTicketsAndRevocation$' -test.v)

set +e
negative=$(systemd-run --quiet --wait --pipe --collect --uid=nobody --property=RuntimeMaxSec=60s \
    "${properties[@]}" --property='RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' \
    "$binary" "${test_args[@]}" 2>&1)
negative_status=$?
set -e
if [[ $negative_status == 0 ]] || ! grep -Fq 'address family not supported by protocol' <<< "$negative"; then
    printf '%s\n' "$negative" >&2
    echo 'The missing-NETLINK negative control did not fail as expected.' >&2
    exit 1
fi
echo 'PASS: the previous socket-family restriction reproduces the startup failure.'
systemd-run --quiet --wait --pipe --collect --uid=nobody --property=RuntimeMaxSec=60s \
    "${properties[@]}" --property="RestrictAddressFamilies=$families" "$binary" "${test_args[@]}"
echo 'PASS: the declared Drive sandbox supports private transfer, receipt, ticket replay denial and revocation without capabilities.'
