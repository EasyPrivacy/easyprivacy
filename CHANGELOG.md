# Changelog

## Unreleased

- Begin Core/VPN/Files application separation with a shared Pub workspace,
  public model/UI packages, scoped Core control broker, and separate app builds.
- Preserve the combined application VPN migration controls and enrollment storage.
- Add independent private-service peer records and v2 network APIs, including
  parent revocation and a legacy peer-state rollback snapshot.
- Connect Core's userspace WireGuard runtime to the production broker and shared
  SDK through pinned local TLS streams, with capability revocation and bounded
  single-use tickets. Keep Files engines explicitly unavailable in its shell.
- Add private-only node setup, a diagnostic probe, service discovery and expiring
  Files receiver grants with scoped firewall rules. Preserve existing VPN state.

- Restore EasyPrivacy launcher, taskbar and title-bar icons missing from the
  feature's older dev base, and use the brand mark in Android notifications.

- Android VPN notification permission handling, live tunnel status, quick
  Connect/Disconnect actions and reopening the existing app screen.
- Windows system tray status, connection controls and reopening the existing
  app window, including after closing it to the tray.
- A saved **Always show VPN status** setting, off by default; otherwise the
  indicator is shown only while the VPN is active or changing state.

## 1.0.0 — 2026-10-19

First completed MVP, accepted by the owner on October 18, 2026.

- Ubuntu 24.04 core and home service-node packages for amd64 and arm64.
- Short-code core verification followed by account authentication, per-device
  signing keys, remembered-device reconnect, device listing and revocation.
- Integrated Windows and Android WireGuard VPN clients with VPS and home exits.
- Outbound home VM connection through the VPS, scoped forwarding/NAT and home
  server access without a public home IP or incoming home port forwarding.
- Management host routes for overlapping local/home LAN ranges.
- Headless Linux service setup and optional Linux GUI service control.
- Persistent Home selection with fail-closed forwarding when its path is lost.

This release promotes the accepted MVP to 1.0.0. It changes release metadata and
documentation; existing authentication, wire protocols, state schemas and trusted
core/device identities remain compatible. Android uses build counter 7 so the
1.0.0 APK can upgrade existing installations. See the
[release notes](docs/releases/1.0.0.md) for artifacts, upgrade steps and current
limitations.
