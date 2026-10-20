# EasyPrivacy MVP revamp

Started: October 16, 2026
Branch: `codex/mvp-revamp`
Starting point: local `origin/main`, commit `3fc0b45` (initial README and logo assets).

## Goals from the owner

- Have a usable MVP by the end of Sunday, October 18, 2026.
- Use the EasyPrivacy app to obtain private Internet access through the owner's server at their parents' house.
- Keep setup and everyday use simple enough to fit around school.
- After the MVP, focus on one feature each week through the end of the year.
- Review what to include and remove before carrying previous implementation choices forward.

The earlier attempts remain in `../../easyprivacy/` and `../dev/`. Their code and
uncommitted changes are preserved. This worktree starts with the minimal project
baseline; no previous application or server implementation has been copied here.

## Agreed working approach

- Use the first iteration as the main visual reference.
- Reuse functionality from the second iteration where it fits the agreed behavior.
- Let the owner's practical descriptions define requirements. Earlier
  architecture and roadmap decisions are reference material, not inherited requirements.

## Agreed weekend scope

- Basic user-facing interfaces for desktop and Android.
- Central node connection and VPN setup capabilities.
- Begin with the connection between a VPS-hosted core and the desktop app.

The home-server Internet access goal remains the overall intended outcome.
The VPS-to-desktop connection is the first implementation milestone.

## Agreed first milestone: install, set up, connect

1. Deliver the core as an Ubuntu `.deb` package, prioritizing easy installation.
   The owner confirmed **Ubuntu 24.04.4 LTS** as the test VPS release.
2. Support separate x86-64 (`amd64`) and ARM64 (`arm64`) builds. The owner
   believes the current test server is x86.
3. Provide a terminal wizard on the VPS that guides the owner through creating
   the core's username and password during setup.
4. Install a background service that listens on a configured server port.
5. Allow the desktop user to enter the core address and the credentials created
   during core setup, then establish a secure connection with visible status.

Connection checks should cover successful authentication, rejection of incorrect
credentials, encrypted communication, and verification of the core's identity.
The initial implementation asks the user to copy the core's certificate
fingerprint from the trusted setup terminal into the desktop. It verifies that
fingerprint before sending credentials. This is a concrete implementation
choice for review, rather than a requirement inherited from earlier iterations.
VPN functionality is subsequent work within the weekend scope; this first
connection test does not demonstrate a working VPN.

## Details still to establish

- The first desktop build targets Windows, matching the current development
  machine. The interface also targets Android.
- Review the implemented setup flow: `sudo easyprivacy-node setup` after package
  installation, with core name, configurable port (default TCP 7444), username,
  and hidden password/confirmation prompts.
- VPS access and firewall configuration for the real connection test.
- Home-server reachability, routing, DNS/IPv6 behavior, and reconnect requirements
  when defining the VPN milestone.
- Available time for installation and testing on the actual devices.

## Weekly delivery proposal

Pick one small feature, agree on observable completion checks, and finish each
week with a usable build. Include fixes and maintenance when they are the most
valuable improvement. Keep larger ideas in a backlog until selected.

## Current status

**Complete: V1.0.0.** The owner verified the working MVP and declared it complete
on October 18, 2026. The project release was designated 1.0.0 on October 19, 2026.
Enrollment, Windows/Android VPN clients, VPS and Home exits, home management
access, and headless/optional-GUI Linux service-node control are implemented.
See [V1.0.0 release notes](releases/1.0.0.md) for artifacts, upgrades and limits.

The following records the decisions and sequence that produced the accepted MVP.

For the home service-node milestone, the owner requested Linux support for
both headless/CLI and GUI deployments. See [home service-node scope and topology
choices](home-service-node.md). The VM is Ubuntu 24.04.3 LTS and is believed to use
a bridged home-LAN adapter, with address 192.168.50.247/24 on ens18. The owner
selected separate encrypted device/VPS and VPS/home legs, trusting the VPS with
forwarding between them. Headless and optional GUI Linux service-node control
share the same daemon. See the linked guide for deployment and verification.

On October 18, 2026, the owner reported that the corrected two-step enrollment
worked well in their testing and concluded initial enrollment development.
For VPN connectivity, the owner selected the VPS as the first
Internet exit, Windows first and Android included. The integrated implementation
and completed owner acceptance are recorded in [VPN milestone](vpn-milestone.md).

The isolated worktree contains the first connection implementation under `core/`
and `app/`. The app reuses the first iteration's theme, logo, and platform
scaffolding. The core adapts the second iteration's service-hardening and
password-verifier approach to terminal setup and direct owner sign-in.
See `core/README.md` for installation and current limitations, and
`connection-milestone.md` for completed local checks. The owner deployed and tested
the servers; the agent did not log into or administratively modify the VPS.

The owner confirmed a successful Windows core connection after identifying the
missing host UFW allow rule. The next accepted authentication direction uses
short pairing codes, a separate random key pair per device, and new-code creation
from an existing paired device's authenticated session. For the MVP, creating a
code has no extra password or PIN prompt. A future optional core setting can
require a short PIN for that action instead of the full account password.
The owner clarified that this exemption applies only to code display. Every
new device verifies the core with the code, then must authenticate the core
account username/password over pinned TLS before its device key is authorized.
Routine reconnects continue to use the saved device key.
See [Device pairing](device-pairing.md) for the specified flow, initial defaults,
security requirements and implementation status. The pairing implementation now
uses shared native RustCrypto SPAKE2, Ed25519 device identities and persistent
revocation. Legacy fingerprint login remains available for compatibility.
