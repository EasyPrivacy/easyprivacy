<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/EasyPrivacy_White.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/EasyPrivacy_Transparant_Black.png">
    <img alt="EasyPrivacy" src="assets/EasyPrivacy_Transparant_Black.png" width="420">
  </picture>
</p>

# EasyPrivacy -- V1.0.0

**Your data should remain yours.**

EasyPrivacy is an open-source privacy infrastructure platform designed to make self-hosting approachable for everyday people. It helps users configure, secure, back up, update, and manage private services on infrastructure they own—from home hardware to a virtual private server—without taking ownership of their accounts, credentials, encryption keys, or data.

## Our commitment

We believe consumer privacy begins with ownership and meaningful choice. You should decide where your data lives, who can access it, how it is protected, and what you want to do with it. EasyPrivacy is designed to keep that control in your hands:

- Your infrastructure, hardware, accounts, credentials, encryption keys, and data remain yours.
- No mandatory EasyPrivacy cloud account is required for normal operation.
- Open-source, replaceable components reduce vendor lock-in.
- Secure defaults, encrypted backups, and clear recovery options help protect what matters.
- Your deployed services should continue working even if EasyPrivacy is no longer available.

## What EasyPrivacy does

EasyPrivacy acts as a unified control plane for trusted open-source services. It simplifies provisioning, networking, security, storage, backups, updates, monitoring, and disaster recovery while leaving users in control of the underlying systems.

The goal is simple: make private, user-owned digital infrastructure practical without requiring people to become systems administrators.

> If EasyPrivacy disappeared tomorrow, users should still be able to access, recover, understand, and operate their infrastructure and data.

## Project status

**V1.0.0 is the first completed MVP.** The owner verified the working MVP on
October 18, 2026; version 1.0.0 designates that milestone on October 19, 2026.

The release includes Ubuntu core and home service-node packages, secure device
enrollment, Windows and Android VPN clients, VPS and home Internet exits, home
server access, and optional Linux GUI control of the home service. The home VM
connects outbound through the VPS without a public IP or router port forwarding.
The two VPN legs are encrypted, and the VPS is trusted with forwarding between
them. IPv4 traffic and DNS use the selected exit; IPv6 remains blocked in the VPN.

The development branch is separating Core, VPN, and Files into independent apps.
See the implementation status linked below for completed and pending work.

The project is now moving to one focused feature at a time. Broader platform
capabilities described above remain the long-term direction; see the release
notes for the scope and limitations of the completed MVP.

- [Ubuntu package installation and setup](core/README.md)
- [V1.0.0 release notes and upgrades](docs/releases/1.0.0.md)
- [Home exit installation and management access](docs/home-service-node.md)
- [Core management application](apps/core/README.md)
- [Optional Internet VPN application](apps/vpn/README.md)
- [Files application development status](apps/files/README.md)
- [Private Drive storage-node setup and candidate status](docs/files-drive.md)
- [App reorganization implementation status](docs/app-reorganization-progress.md)
- [Private-network development update and rollback](docs/private-network-upgrade.md)
- [Device pairing and authorization](docs/device-pairing.md)
- [Agreed scope and practical requirements](docs/mvp-revamp.md)
- [Connection milestone and local validation](docs/connection-milestone.md)
- [VPN setup and validation](docs/vpn-milestone.md)
