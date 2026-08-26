<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/EasyPrivacy_White.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/EasyPrivacy_Transparant_Black.png">
    <img alt="EasyPrivacy" src="assets/EasyPrivacy_Transparant_Black.png" width="420">
  </picture>
</p>

# EasyPrivacy -- V0.0.0

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

EasyPrivacy is currently in the early design and development stage. Version 0.1 begins with an existing Linux server that the owner already controls.

The initial implementation includes:

- a Flutter management app targeting Windows, Linux, and Android;
- a Go agent targeting Linux servers;
- authenticated reporting of real hostname, uptime, memory, and storage data;
- a responsive dashboard based on the initial interface concept;
- a manual Linux systemd installer with conservative network defaults;
- automated Dart, Flutter, and Go tests.

Windows Server remains an intended future server platform but is not part of the initial implementation.

## Repository layout

```text
app/        Windows, Linux, and Android management app
agent/      Linux server agent and systemd packaging
docs/       Architecture and testing documentation
assets/     Project identity assets
```

## Test the initial version

The complete platform checklist, Linux agent setup, SSH tunnel instructions, expected results, and security-negative tests are in [docs/manual-testing.md](docs/manual-testing.md).

The current component boundary and explicitly deferred work are documented in [docs/architecture.md](docs/architecture.md).

Linux desktop validation is currently postponed until a test device is available. The restart checklist is preserved in [docs/deferred-linux-desktop-review.md](docs/deferred-linux-desktop-review.md).

To continue in a fresh development conversation, use [docs/next-development-cycle-handoff.md](docs/next-development-cycle-handoff.md).
