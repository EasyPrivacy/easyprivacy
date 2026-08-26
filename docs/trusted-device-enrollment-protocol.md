# Trusted-Device Enrollment and One-Time SSH Bootstrap

## Status and scope

This document records the reviewed version 0.1 protocol boundary for enrolling an owner's personal device with an EasyPrivacy Linux agent. It applies to the initial product model: one owner, one deployment, and one security domain with independently revocable personal devices.

The first implementation slice is intentionally smaller than the complete flow. It provides agent-side issuance, authenticated API use, listing, and revocation of distinct device credentials. The owner invokes enrollment through an already verified SSH session and transfers the credential to the app manually. Automatic SSH connection, platform-secure client storage, certificate provisioning, owner recovery, and an in-app device-management screen are not implemented by this slice.

This is not a multi-user identity protocol and does not turn the shared development token into finished per-device authentication.

## Security and product invariants

- The deployment, SSH account, host keys, device credentials, recovery material, and data remain under the owner's control.
- Normal operation does not require an EasyPrivacy-operated account or cloud service.
- Unknown or changed SSH host keys and unknown HTTPS certificates are never accepted silently.
- SSH passwords, private keys, agent handles, and administrator credentials exist only for the active bootstrap session and are not copied into EasyPrivacy state.
- Each device receives a distinct random credential that can be revoked without changing other device credentials or server SSH credentials.
- The server does not retain the plaintext device credential after issuing it once.
- Enrollment is explicit; SSH login or previous app use does not itself make a device trusted.
- Losing every device must not destroy the owner identity. Recovery authorization and recovery-kit format require a separate review.
- Deployed services remain usable if EasyPrivacy or any future EasyPrivacy-operated service is unavailable.

## Trust anchors and assets

### Initial server trust anchor

The initial trust anchor is the Linux server's SSH host key, verified against an independent source such as the server console, VPS provider console, or a fingerprint the owner previously recorded. Discovering a key over the same untrusted network is not sufficient verification.

Enrollment must show the server address, key algorithm, and SHA-256 fingerprint. A first-seen key requires explicit confirmation after comparison. A changed key is a hard stop until resolved out of band; a generic continue button must not bypass it.

### Bootstrap authentication material

The owner may use an SSH password, private key, or existing SSH agent. That material authenticates only the temporary bootstrap session. It remains in memory only while needed, is never written to EasyPrivacy configuration or logs, and never becomes the normal management credential.

### Device credential

The initial device credential is an opaque bearer credential containing a non-secret device identifier and at least 256 bits of random secret material. It is safe only inside an authenticated encrypted channel. The agent stores a SHA-256 digest because a uniformly random 256-bit secret does not require a password-hardening function. The plaintext credential is shown once and must not appear in logs or agent-state backups.

The device name is owner-supplied display metadata, not an authenticated human identity.

### Recovery material

Recovery material is independent of device credentials and EasyPrivacy-operated infrastructure. Its format, rotation, quorum, and authority to revoke devices are deliberately not selected here. Implementing those choices would change the recovery and trust model and requires owner direction.

## Reviewed protocol

### 1. Preflight and host verification

1. The app collects server address, SSH user and port, and device display name.
2. It explains which SSH authentication method will be used and that it will not be retained.
3. It opens an SSH handshake without accepting the presented host key.
4. It shows the key algorithm and SHA-256 fingerprint.
5. The owner compares that fingerprint with an independent source and explicitly approves it.
6. The app pins the approved key for bootstrap. A mismatch or later key change stops the operation.

### 2. One-time administrative session

1. The app authenticates over the pinned SSH connection with the owner-supplied method.
2. It checks Linux and systemd prerequisites and reports intended commands and file changes.
3. With explicit owner action, it installs or updates the agent and initializes agent state.
4. Installer output does not echo SSH secrets, private keys, or existing device credentials.
5. The app closes the administrative session after enrollment and retains no administrator login material.

### 3. Enroll the current app installation

1. Through verified SSH, bootstrap invokes the agent's explicit enrollment command as the agent service account.
2. The agent generates a random device ID and random secret locally.
3. It stores only the digest and non-secret metadata in owner-only state.
4. It returns the plaintext credential once through SSH.
5. The app proves the credential works over an encrypted management channel.
6. The app stores it in platform-secure storage and clears temporary copies.

Step 6 is required before automated enrollment is complete. The current app still keeps credentials only in process memory.

### 4. Normal management transport

The bearer credential is never sent over remote plaintext HTTP. Version 0.1 may use a verified, pinned SSH tunnel or HTTPS whose certificate/public key is pinned or chains to an already trusted root.

The current slice uses the localhost API through a manually created, verified SSH tunnel. Long-term transport, certificate lifecycle, and tunnel-key lifecycle remain future work. The app must not fall back to an unverified certificate or remote HTTP.

### 5. List, revoke, add, and recover

The owner can list device IDs, display names, creation times, and active/revoked state without exposing credentials. Revocation removes one device from the active set and applies on its next API request without restarting the agent.

This slice exposes listing and revocation only through the CLI over owner-controlled SSH. Letting one enrolled device revoke another through the API needs a separate authorization review; this document does not grant every bearer credential that authority.

Repeating verified SSH enrollment can add another personal device without sharing an existing credential. A future approval flow from an enrolled device may improve usability, but its expiration, replay protection, and recovery interaction are not selected here.

If every device is lost, recovery must use independent owner-controlled material and allow missing devices to be revoked. EasyPrivacy must not claim complete lost-device recovery until that protocol is reviewed and implemented.

## Threat model

| Threat | Required control | Current slice |
|---|---|---|
| Network attacker impersonates server | Out-of-band SSH host-key verification and pinning | Documented; app automation pending |
| Unknown/replaced HTTPS certificate | Pin or validate; never auto-accept | Remote HTTP rejected; enrollment pending |
| App leaks SSH administrator credential | Never persist or log; clear after bootstrap | Automated SSH handling pending |
| Server state or backup leaks a device credential | Store only digest and metadata | Implemented |
| One device is lost or compromised | Distinct credential and targeted revocation | Implemented through CLI and authenticator |
| Credential is replayed from network | Require verified encrypted transport | Manual verified SSH tunnel required |
| Server is compromised | Treat server as inside deployment boundary; keep recovery independent | Recovery pending |
| EasyPrivacy vendor disappears/compromised | No mandatory vendor service or vendor-held root | Preserved |
| Malicious name/ID alters paths or terminal output | Validate IDs and reject control characters | Implemented |
| Credential state is corrupt | Fail authentication closed; never log submitted credential | Implemented |

## Smallest verified vertical slice

```text
easyprivacy-agent device enroll --state-dir <path> --name <device name>
easyprivacy-agent device list --state-dir <path>
easyprivacy-agent device revoke --state-dir <path> --id <device id>
```

Enrollment prints the credential once. Listing prints neither credentials nor digests. Revocation moves the immutable record out of the active set, so the running API rejects it without restart.

The agent continues accepting the existing shared development token during this compatibility slice. It remains a development limitation. Removing it requires automated bootstrap, secure client storage, and a migration path for tested installations.

## Verification criteria

Automated tests prove that credentials and IDs are distinct, active credentials authenticate, plaintext credentials are absent from state, listing exposes only metadata, revocation invalidates only one device without restart, malformed/corrupt input fails safely, and the legacy development token remains a separate compatibility mechanism.

Manual validation must also exercise the CLI through independently verified SSH and repeat the status request through the tunnel. That manual path is not automatic SSH bootstrap or platform-secure credential storage.
