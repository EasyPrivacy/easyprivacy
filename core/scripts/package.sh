#!/usr/bin/env bash
set -euo pipefail
core_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
arch=${1:-amd64}
case "$arch" in amd64|arm64) ;; *) printf 'Usage: package.sh [amd64|arm64]\n' >&2; exit 2 ;; esac
version=${VERSION:-$(cat "$core_dir/../VERSION")}
[[ "$version" =~ ^[0-9][a-zA-Z0-9.+~]*$ ]] || { printf 'Invalid package VERSION\n' >&2; exit 2; }
go_bin=${EASYPRIVACY_GO:-go}
mkdir -p "$core_dir/dist"
binary="$core_dir/dist/easyprivacy-node-linux-$arch"
cd "$core_dir"
bash "$core_dir/scripts/build-pairing.sh" "$arch"
if [[ "$arch" == arm64 ]]; then export CC=${CC:-aarch64-linux-gnu-gcc}; fi
CGO_ENABLED=1 GOOS=linux GOARCH="$arch" "$go_bin" build -tags netgo,osusergo -trimpath -ldflags "-X main.version=$version" -o "$binary" ./cmd/easyprivacy-node
staging=$(mktemp -d /tmp/easyprivacy-package.XXXXXXXX)
cleanup() {
    case "$staging" in /tmp/easyprivacy-package.*) rm -rf -- "$staging" ;; esac
}
trap cleanup EXIT
mkdir -p "$staging/DEBIAN" "$staging/usr/bin" "$staging/usr/lib/systemd/system" "$staging/usr/share/doc/easyprivacy-node"
install -m 0755 "$binary" "$staging/usr/bin/easyprivacy-node"
install -m 0644 "$core_dir/packaging/easyprivacy-node.service" "$staging/usr/lib/systemd/system/"
install -m 0644 "$core_dir/packaging/easyprivacy-vpn.service" "$staging/usr/lib/systemd/system/"
install -m 0644 "$core_dir/packaging/easyprivacy-service.service" "$staging/usr/lib/systemd/system/"
install -m 0644 "$core_dir/packaging/easyprivacy-drive.service" "$staging/usr/lib/systemd/system/"
mkdir -p "$staging/usr/lib/tmpfiles.d"
install -m 0644 "$core_dir/packaging/easyprivacy-vpn.tmpfiles" "$staging/usr/lib/tmpfiles.d/easyprivacy-vpn.conf"
install -m 0644 "$core_dir/README.md" "$staging/usr/share/doc/easyprivacy-node/README"
install -m 0644 "$core_dir/../native/pairing/THIRD-PARTY-NOTICES.txt" "$staging/usr/share/doc/easyprivacy-node/"
install -m 0644 "$("$go_bin" env GOROOT)/LICENSE" "$staging/usr/share/doc/easyprivacy-node/GO-LICENSE"
for script in postinst prerm postrm; do
    install -m 0755 "$core_dir/packaging/$script" "$staging/DEBIAN/$script"
done
cat > "$staging/DEBIAN/control" <<EOF
Package: easyprivacy-node
Version: $version
Architecture: $arch
Maintainer: EasyPrivacy contributors <maintainers@easyprivacy.invalid>
Section: net
Priority: optional
Depends: systemd, init-system-helpers (>= 1.52), passwd, util-linux, libc6 (>= 2.39), libgcc-s1, wireguard-tools, iproute2, iptables
Description: EasyPrivacy core and home service node
 Terminal setup, encrypted connections and owner authentication.
 Targets Ubuntu 24.04 LTS with VPS and outbound home WireGuard VPN exits.
EOF
chmod 0755 "$staging" "$staging/DEBIAN"
chmod 0644 "$staging/DEBIAN/control"
package="$core_dir/dist/easyprivacy-node_${version}_${arch}.deb"
dpkg-deb --root-owner-group --build "$staging" "$package"
cd "$core_dir/dist"
sha256sum "$(basename "$package")" > "$(basename "$package").sha256"
printf 'Package: %s\n' "$package"
