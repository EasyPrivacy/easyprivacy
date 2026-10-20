#!/usr/bin/env bash
set -euo pipefail
app_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
flutter_bin=${EASYPRIVACY_FLUTTER:-flutter}
arch=$(dpkg --print-architecture)
case "$arch" in amd64) rust_target=x86_64-unknown-linux-gnu ;; arm64) rust_target=aarch64-unknown-linux-gnu ;; *) exit 2 ;; esac
version=${VERSION:-$(cat "$app_dir/../VERSION")}
[[ "$version" =~ ^[0-9][a-zA-Z0-9.+~]*$ ]] || exit 2
stage=$(mktemp -d /tmp/easyprivacy-linux-build.XXXXXXXX)
cleanup() { case "$stage" in /tmp/easyprivacy-linux-build.*) rm -rf -- "$stage" ;; esac; }
trap cleanup EXIT
cd "$app_dir"
tar --exclude=ephemeral --exclude=generated_plugins.cmake --exclude=generated_plugin_registrant.cc --exclude=generated_plugin_registrant.h -cf - lib assets linux pubspec.yaml pubspec.lock analysis_options.yaml | tar -xf - -C "$stage"
cd "$stage"
"$flutter_bin" pub get
"$flutter_bin" build linux --release
bundle="$stage/build/linux/$(uname -m)/release/bundle"
if [[ "$arch" == amd64 ]]; then bundle="$stage/build/linux/x64/release/bundle"; else bundle="$stage/build/linux/arm64/release/bundle"; fi
install -m 0755 "$app_dir/../native/pairing/target/$rust_target/release/libeasyprivacy_pairing.so" "$bundle/lib/"
mkdir -p "$stage/package/DEBIAN" "$stage/package/usr/lib/easyprivacy-desktop" "$stage/package/usr/bin" "$stage/package/usr/share/applications" "$stage/package/usr/share/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$stage/package/usr/lib/easyprivacy-desktop/"
cat > "$stage/package/usr/bin/easyprivacy-desktop" <<'EOF'
#!/bin/sh
exec /usr/lib/easyprivacy-desktop/easyprivacy "$@"
EOF
chmod 0755 "$stage/package/usr/bin/easyprivacy-desktop"
cat > "$stage/package/usr/share/applications/org.easyprivacy.easyprivacy.desktop" <<'EOF'
[Desktop Entry]
Name=EasyPrivacy
Comment=Connect to your core and manage your home service node
Exec=easyprivacy-desktop
Icon=easyprivacy
Terminal=false
Type=Application
Categories=Network;
EOF
install -m 0644 "$app_dir/assets/easyprivacy-mark.png" "$stage/package/usr/share/icons/hicolor/256x256/apps/easyprivacy.png"
cat > "$stage/package/DEBIAN/control" <<EOF
Package: easyprivacy-desktop
Version: $version
Architecture: $arch
Maintainer: EasyPrivacy contributors <maintainers@easyprivacy.invalid>
Section: net
Priority: optional
Depends: easyprivacy-node (>= $version), libgtk-3-0t64, libsecret-1-0, libstdc++6, libc6 (>= 2.39), libgcc-s1, libjsoncpp25, pkexec, gnome-keyring, dbus-user-session
Description: EasyPrivacy optional Linux desktop interface
 Pair with a core and manage the same home service node as the headless CLI.
EOF
mkdir -p "$app_dir/build"
package="$app_dir/build/easyprivacy-desktop_${version}_${arch}.deb"
dpkg-deb --root-owner-group --build "$stage/package" "$package"
cd "$app_dir/build"
sha256sum "$(basename "$package")" > "$(basename "$package").sha256"
mkdir -p "$app_dir/build/linux-package"
cp -a "$bundle/." "$app_dir/build/linux-package/"
printf 'Linux GUI package: %s\n' "$package"
