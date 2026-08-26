# EasyPrivacy Next Development Cycle Handoff

## Purpose

Use this document to start a new EasyPrivacy development conversation without relying on the previous conversation history.

## Workspace

```text
Workspace root:
C:\Users\kason\OneDrive\Desktop\Personal\Projects\EasyPrivacy

Source repository:
C:\Users\kason\OneDrive\Desktop\Personal\Projects\EasyPrivacy\easyprivacy

Current development branch:
secure-device-enrollment-bootstrap
```

The repository currently contains uncommitted implementation and documentation changes. A new development conversation must treat every existing change as user-owned, inspect `git status`, and preserve those changes. It must not reset, discard, or overwrite them.

## Required reading

Read these files before proposing or implementing the next milestone:

1. `design_docs/EasyPrivacy — Initial Concept Specification.md`
2. `easyprivacy/docs/architecture.md`
3. `easyprivacy/docs/manual-testing.md`
4. `easyprivacy/docs/deferred-linux-desktop-review.md`
5. `easyprivacy/README.md`
6. `easyprivacy-interface-concept.png`

The concept specification and interface image are in the workspace root, outside the nested source repository.

## Product decisions already made

- The EasyPrivacy management app targets Windows, Linux, and Android.
- The initial server agent targets Linux.
- Windows Server remains a future target, but its implementation and workload architecture are deferred.
- Version 0.1 starts with a Linux server or VPS the owner already controls.
- Cloud-provider VPS creation is deferred.
- EasyPrivacy must not require a vendor-hosted account or vendor-controlled cloud service.
- The management interface is a native installed app, not a vendor-hosted browser application.
- Deployed upstream services must continue operating if EasyPrivacy is unavailable.
- The initial deployment represents one owner and one security domain.

## Implemented in the current development tree

### Management app

- Flutter application targeting Windows, Linux, and Android;
- responsive onboarding and dashboard based on the interface concept;
- existing-agent connection form;
- remote plain-HTTP rejection and localhost HTTP allowance for SSH-tunnel development;
- authenticated status retrieval;
- real hostname, operating system, architecture, uptime, memory, and storage display;
- demo dashboard;
- placeholder navigation for future functional areas;
- Dart analysis and Flutter widget tests.

### Linux agent

- Go management agent;
- versioned JSON health and status endpoints;
- bearer-token authentication with constant-time digest comparison;
- distinct device-credential issuance, digest-only storage, listing, and revocation through the agent CLI;
- immediate API rejection of a revoked device credential without an agent restart;
- localhost-only HTTP default;
- rejection of non-loopback HTTP unless TLS is configured;
- Linux hostname, uptime, memory, and filesystem collection;
- systemd service and manual installer;
- Go unit tests, vet checks, and Linux cross-build verification.

## Toolchain compatibility

- Flutter 3.44.3 or later in the current development line;
- Dart `>=3.12.0 <4.0.0`;
- Go 1.26 or later for agent development;
- Windows and Android debug builds have completed successfully in the current workspace.

## Manual validation status

| Area | Status |
|---|---|
| Windows management app | User-tested August 26, 2026; no failures reported |
| Android management app | User-tested August 26, 2026; no failures reported |
| Linux server agent | User-tested August 26, 2026; no failures reported |
| Linux desktop app | Deferred until a Linux desktop device is available |
| Complete SSH-tunnel app-to-agent path | Not separately confirmed |

See `docs/manual-testing.md` for the detailed regression suite.

## Known limitations that must remain explicit

- Automatic SSH bootstrap is not implemented.
- The current installer is manual.
- The agent still accepts one shared development token for compatibility; it is not finished per-device authentication.
- Distinct credentials currently require a manual command through an independently verified SSH session.
- The app retains whichever credential is entered only for the current process; platform-secure storage is not implemented.
- The app does not yet verify or pin a self-hosted agent certificate during enrollment.
- Services, backups, updates, recovery, and security-management pages are not functional.
- Linux desktop compilation and visual testing are deferred.
- The current build is a development prototype and is not production-ready.

## Recommended next milestone

Continue secure owner-device enrollment and one-time SSH bootstrap before deploying the first upstream service. The reviewed protocol and threat model are in `docs/trusted-device-enrollment-protocol.md`, and the smallest agent-side credential/revocation slice is implemented.

The next cycle should first produce a reviewed protocol and threat model, then implement the smallest secure vertical slice:

1. Connect to an existing Linux server through SSH.
2. Show and require explicit verification of the SSH host-key fingerprint.
3. Install or update the EasyPrivacy agent.
4. Invoke the implemented agent enrollment command for the current app installation.
5. Establish authenticated encrypted management without trusting an unknown certificate.
6. Store the distinct credential using platform-secure storage.
7. Remove bootstrap material and avoid retaining SSH administrator credentials.
8. Add an app device list and revocation flow after reviewing cross-device authorization.
9. Add recovery behavior that does not depend on an EasyPrivacy-operated account.

Private DNS is the recommended first managed service after this identity and transport boundary is validated.

Do not silently accept self-signed certificates, store SSH passwords, expose the agent over unauthenticated HTTP, or represent the shared development token as finished device enrollment.

## Copy-ready prompt for a new development conversation

```text
Continue the next EasyPrivacy development cycle in:
C:\Users\kason\OneDrive\Desktop\Personal\Projects\EasyPrivacy

Before changing anything, read these files completely:
- design_docs/EasyPrivacy — Initial Concept Specification.md
- easyprivacy/docs/next-development-cycle-handoff.md
- easyprivacy/docs/architecture.md
- easyprivacy/docs/manual-testing.md
- easyprivacy/docs/deferred-linux-desktop-review.md
- easyprivacy/README.md

Also inspect easyprivacy-interface-concept.png and the current source tree. Run git status in the nested easyprivacy repository. All existing changes are user-owned and may be uncommitted; preserve them.

Windows, Android, and the Linux server agent were manually tested on August 26, 2026 with no failures reported. Linux desktop app testing is intentionally deferred. The full app-to-agent SSH-tunnel path is not separately confirmed.

Start the next cycle by reviewing and documenting the secure trusted-device enrollment and one-time SSH bootstrap protocol. Then implement the smallest verified vertical slice. Do not introduce a mandatory vendor cloud, silently trust certificates, retain SSH administrator credentials, or describe the current shared development token as finished per-device authentication.

Stop for direction before making a security or product decision that materially changes the ownership, recovery, identity, or trust model.
```

## What to provide if the new conversation cannot access this workspace

Provide a copy or archive of the `easyprivacy` repository plus:

- `design_docs/EasyPrivacy — Initial Concept Specification.md`;
- `easyprivacy-interface-concept.png`;
- this handoff document.

Do not include development tokens, passwords, SSH private keys, server IP addresses that should remain private, or recovery material.
