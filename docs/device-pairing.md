# Device pairing and remembered device identity

Status: included in EasyPrivacy **1.0.0**, the first completed MVP. Initial
enrollment was accepted by the owner on October 18, 2026.
This document records the accepted behavior and protocol requirements. Build and
real-device validation results are tracked in `connection-milestone.md`. Legacy
fingerprint/password login is retained for compatibility and is not used as an
automatic fallback from failed pairing or device authentication.

## Accepted requirements

- Give each device its own randomly generated key pair. Keep its private key on
  that device; the core stores its public key and authorization record.
- Pair a new device with a short, temporary code instead of typing the core's
  certificate fingerprint. Pairing must work with a self-signed core certificate
  and an IP address, without requiring a domain or public certificate authority.
- After the code verifies the core, require the core account username/password
  over pinned TLS before authorizing any new device. The exemption from password
  re-entry applies only to displaying a code on an already authorized device.
- Allow a currently authorized, paired device to request and display a code
  through its authenticated connection, without an additional password or PIN
  prompt in the MVP. The core issues and controls the code; devices cannot mint
  usable enrollment codes offline.
- Later, let the owner enable an optional short PIN requirement for creating
  pairing codes. This is a separate setting and is outside the initial MVP.
- Reconnect using the enrolled device's private key. Support a device list and
  server-side revocation of a lost or unwanted device.

## First device

1. Install the Ubuntu package and complete the trusted terminal setup, including
   the owner's username and password.
2. Ask the core to create a pairing code in that terminal. Provide a terminal
   command for obtaining a new code on an existing installation as well.
3. In the app, enter the core address, a name for this device, and the code.
4. The app generates a fresh device key pair locally. A password-authenticated
   key exchange (PAKE) authenticates the pairing exchange using the temporary code.
5. The exchange authenticates the core identity and binds the exact proposed
   device public key, but does not authorize it. Show **Core verified**, then
   request the core account username and password. Send these with a separately
   derived enrollment proof only over a fresh TLS connection pinned to that core.
6. The core verifies the proof and account credentials before durably authorizing
   the device. The app then saves its verified identity and device credential,
   and proves possession of its new device private key. No long fingerprint entry
   is required, and the account password is not needed for routine reconnects.

## Additional devices

1. On a paired, connected device, choose **Add device**.
2. The core checks the authenticated session and the device's current
   authorization before issuing one new pairing code. The requesting device
   displays the code and its remaining lifetime. No extra password or PIN is
   requested for this action in the MVP.
3. Enter the address and code on the new device, then its account credentials,
   and complete the same pairing
   flow. The existing device's private key is never copied to the new device.

A live authenticated session from a currently authorized, paired device is
sufficient to create a code in the MVP. An unpaired device, an expired session,
or a revoked device cannot create codes. The terminal command remains available
if no paired device is accessible.

## Future optional PIN protection

Provide an owner-controlled core setting that requires a short PIN before a
paired device can create a pairing code. Keep this setting disabled by default;
enabling it adds the PIN check to **Add device**, without requiring the full
account password for that action or for routine device reconnects.

Enforce the enabled policy on the core so an app cannot bypass it by omitting
its PIN screen. The reusable owner PIN is distinct from each temporary pairing
code. Define PIN setup/change/recovery, protected verifier storage and attempt
limits when implementing this feature. No PIN setting, prompt or verifier is
required in the initial MVP.

## Initial defaults

- A uniformly random **eight-digit** code, grouped for readability. Accept
  pasted digits with grouping spaces or hyphens; preserve leading zeros.
- **Five minutes** of validity, measured from creation with no extension on use.
- A ten-second interval between code creations, enforced on the core.
- One successful account enrollment consumes the code. Permit at most **five
  started pairing attempts**; after that no new verification can begin, while
  already verified requests may finish account enrollment before expiry.
  Reserve attempts atomically at exchange start, including parallel or
  abandoned attempts; invalid exchanges must not provide unlimited guesses.
- Only one active code per core for the single-owner MVP. Creating a replacement
  invalidates the old code and its in-progress exchanges. Restart invalidates all
  pairing codes and pending exchanges; existing device authorizations persist.
- Verified enrollments expire with their original code. Each permits at most
  five account-password attempts, in addition to shared source/global rate limits
  and a two-request password-work concurrency limit. Only a successful account
  enrollment consumes the code; wrong credentials never authorize a device.
- Bound pending exchanges, body sizes, expensive work, code-generation requests,
  and authentication attempts. Apply both global and source-based limits.
- Do not log codes, PAKE secrets, passwords, private keys or bearer credentials.

## Protocol requirements

The code is a low-entropy secret. Do not implement it as a password-derived
signing key, a bearer token sent to an unverified server, a public hash checked
offline, or an ordinary TLS pre-shared key. Rate limiting cannot repair a
protocol that lets captured traffic validate password guesses offline.

The implementation uses RustCrypto `spake2` 0.4.0 through a small shared native
wrapper, compiled for Linux amd64/arm64, Windows x64 and Android's three APK
architectures. This is balanced SPAKE2 using the upstream Ed25519 encoding, not
SPAKE2+ or a claim of RFC 9383 wire compatibility. The same implementation runs
on both sides, with Go and Dart independently forming context hashes and HMAC
confirmation messages. The eight-digit secret is temporary and kept in RAM.

The upstream library has not received an independent security audit, nor has our
integration. Source inspection, unit tests and live interoperability/interception
tests do not establish an independent audit. Dependency versions are locked;
upstream MIT and dependency notices are distributed with the app and package.

Authenticate the protocol version, participant roles, fresh exchange identifier,
core identity, intended target, and new device public key in the pairing
transcript/confirmation. A network intermediary must not be able to substitute
its own core certificate or enroll its own device key by relaying the exchange.
Require mutual key confirmation and an authenticated enrollment result.

Protocol `easyprivacy.pairing.v2` separates verification from enrollment. The
client and server derive an enrollment proof with a distinct HMAC label; it is
never sent through the provisional connection. The server retains only its hash
and the exact pending device metadata. A new, pinned TLS request must present it
with valid account credentials. Recheck generation, expiry, creator authorization
and one-use state after password work before committing. Older code-only clients
cannot complete the changed transcript; new apps reject an older core's protocol.

Any provisional connection used to exchange PAKE messages must be isolated from
ordinary authenticated requests. It must never send account passwords, session
tokens or other application data before core identity verification. After pairing,
use the authenticated saved core identity for the normal protected connection.
Do not silently fall back to trusting an unknown certificate, replace an existing
pin without an explicit trusted recovery flow, or downgrade to password login.

Device login must use a fresh, single-use, expiring server challenge and a
signature bound to the device, core and protocol context. Reject replay and
revoked keys. Store private keys in platform-protected local storage; do not
assume hardware-backed, non-exportable storage without implementing it.

Keep immutable core identity/password state separate from service-writable
device authorization records. Define atomic durable updates, bounded device
counts, restrictive ownership, and recovery without resetting the core identity.
Existing installations retain their credentials and fingerprint during upgrades;
the new flow must have a deliberate compatibility path before changing defaults.

## Device management

- List authorized device names and identifiers so the owner can distinguish them.
- Revocation disables the selected device's future authentication and its active
  sessions. Check authorization on authenticated requests; a live session must
  not bypass revocation until its normal expiration.
- Recheck authorization when creating codes and committing enrollments so a
  revoked device cannot continue a pending privileged operation.
- Disconnect closes the current session. It does not silently remove pairing.
- Terminal administration must offer recovery and revocation if no paired
  device remains available.

## Acceptance checks before changing the builds

- First pairing succeeds against a self-signed core using its IP address.
- A valid code without account credentials, a wrong username/password, or valid
  credentials without the code-derived enrollment proof never authorizes a device.
- Passwords and enrollment proofs cannot reach a TLS-terminating pairing relay.
- Windows and Android produce compatible PAKE exchanges; validate against the
  selected implementation's independent vectors or interoperability harness.
- Wrong, expired, exhausted, reused and replaced codes fail. Parallel exchanges
  cannot exceed the attempt budget or enroll multiple devices with one code.
- Tampered transcripts, substituted core/device keys, replay and a TLS-terminating
  intermediary cannot obtain a trusted connection or usable session token.
- Device keys persist across app/core restarts and differ between devices.
- A paired device reconnects without the owner password or fingerprint entry.
- Creating a code succeeds from a currently authorized, paired device's live
  authenticated session without an additional password or PIN. Unpaired devices,
  missing/expired sessions and revoked devices cannot create codes.
- Revocation blocks both new logins and previously issued sessions.
- Existing state survives upgrades; failed enrollment and storage writes do not
  replace the owner's core identity or leave an unverified local profile trusted.
- Test the complete flows in the Windows release and on the connected Pixel,
  including reconnect, expiry, cancellation and removal of an authorized device.

## References

- [SPAKE2, RFC 9382](https://www.rfc-editor.org/rfc/rfc9382.html)
- [SPAKE2+, RFC 9383](https://www.rfc-editor.org/rfc/rfc9383.html)
- [TLS 1.3 external PSKs and password limitations](https://www.rfc-editor.org/rfc/rfc8446.html#section-2.2)
- [TLS certificate private-key proof](https://www.rfc-editor.org/rfc/rfc8446.html#section-4.4.3)
- [NIST password authentication and protected channels](https://pages.nist.gov/800-63-4/sp800-63b.html#passwordver)
