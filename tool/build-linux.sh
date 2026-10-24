#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app=${1:-core}
case "$app" in core|files) ;; *) printf 'Supported Linux apps: core, files\n' >&2; exit 2 ;; esac
flutter_bin=${EASYPRIVACY_FLUTTER:-flutter}
stage=$(mktemp -d /tmp/easyprivacy-workspace.XXXXXXXX)
cleanup() { case "$stage" in /tmp/easyprivacy-workspace.*) rm -rf -- "$stage" ;; esac; }
trap cleanup EXIT
cd "$root"
tar --exclude=build --exclude=.dart_tool --exclude=.gradle --exclude=ephemeral --exclude=.idea --exclude=.flutter-plugins-dependencies --exclude=generated_plugins.cmake --exclude=generated_plugin_registrant.cc --exclude=generated_plugin_registrant.h -cf - apps packages pubspec.yaml pubspec.lock analysis_options.yaml | tar -xf - -C "$stage"
cd "$stage"
"$flutter_bin" pub get
cd "apps/$app"
"$flutter_bin" build linux --release --no-pub
bundle="$stage/apps/$app/build/linux/$(uname -m)/release/bundle"
if [[ "$(uname -m)" == x86_64 ]]; then bundle="$stage/apps/$app/build/linux/x64/release/bundle"; fi
if [[ "$app" == core ]]; then
    arch=$(dpkg --print-architecture)
    case "$arch" in amd64) target=x86_64-unknown-linux-gnu ;; arm64) target=aarch64-unknown-linux-gnu ;; *) exit 2 ;; esac
    install -m 0755 "$root/native/pairing/target/$target/release/libeasyprivacy_pairing.so" "$bundle/lib/"
    install -m 0755 "$root/apps/core/native/linux/easyprivacy-core-runtime" "$bundle/"
fi
output="$root/apps/$app/build/linux-package"
mkdir -p "$output"
cp -a "$bundle/." "$output/"
version=$(cat "$root/VERSION")
cd "$output"
tar -czf "../easyprivacy-$app-linux-$version-$(uname -m).tar.gz" .
printf 'Linux bundle: %s\n' "$output"



if [[ "$app" == core ]]; then
    package_root="$stage/package"
    mkdir -p "$package_root/DEBIAN" "$package_root/usr/lib/easyprivacy-desktop" "$package_root/usr/bin" "$package_root/usr/share/applications" "$package_root/usr/share/icons/hicolor/256x256/apps"
    cp -a "$bundle/." "$package_root/usr/lib/easyprivacy-desktop/"
    cat > "$package_root/usr/bin/easyprivacy-desktop" <<'EOF'
#!/bin/sh
exec /usr/lib/easyprivacy-desktop/easyprivacy "$@"
EOF
    chmod 0755 "$package_root/usr/bin/easyprivacy-desktop"
    cat > "$package_root/usr/share/applications/org.easyprivacy.easyprivacy.desktop" <<'EOF'
[Desktop Entry]
Name=EasyPrivacy Core
Comment=Manage your core, devices and home service node
Exec=easyprivacy-desktop
Icon=easyprivacy
Terminal=false
Type=Application
Categories=Network;
StartupWMClass=org.easyprivacy.easyprivacy
EOF
    install -m 0644 "$bundle/data/easyprivacy.png" "$package_root/usr/share/icons/hicolor/256x256/apps/easyprivacy.png"
    cat > "$package_root/DEBIAN/control" <<EOF
Package: easyprivacy-desktop
Version: $version
Architecture: $arch
Maintainer: EasyPrivacy contributors <maintainers@easyprivacy.invalid>
Section: net
Priority: optional
Depends: easyprivacy-node (>= $version), libgtk-3-0t64, libsecret-1-0, libstdc++6, libc6 (>= 2.39), libgcc-s1, libjsoncpp25, pkexec, gnome-keyring, dbus-user-session
Description: EasyPrivacy Core desktop interface
 Pair with a core and manage devices and the home service node.
EOF
    artifact="$root/apps/core/build/easyprivacy-desktop_${version}_${arch}.deb"
    dpkg-deb --root-owner-group --build "$package_root" "$artifact"
    (cd "$(dirname "$artifact")" && sha256sum "$(basename "$artifact")" > "$(basename "$artifact").sha256")
    printf 'Linux Core package: %s\n' "$artifact"
fi
