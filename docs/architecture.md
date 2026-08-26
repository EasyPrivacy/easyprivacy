# EasyPrivacy Initial Architecture

EasyPrivacy version 0.1 has two independently deployable components.

```text
Windows / Linux / Android management app
                  |
                  | authenticated management API
                  v
        Linux EasyPrivacy agent
                  |
                  v
    user-owned services and storage
```

## Management app

The management app is a Flutter application targeting Windows, Linux, and Android. It is a native installed application, not a vendor-hosted web interface.

The app currently supports:

- connecting to an existing agent;
- refusing unencrypted remote HTTP connections;
- retrieving authenticated system health, uptime, memory, and storage data;
- a responsive overview based on the interface concept;
- a clearly identified demonstration dashboard.

The version 0.1 app keeps whichever credential is entered only for the current app process. The agent can now issue distinct device credentials through its CLI, authenticate API requests with them, and revoke them independently. Automatic enrollment and platform-secure app storage are not implemented. The original shared development token remains temporarily accepted for compatibility and is not finished per-device authentication.

## Linux agent

The agent is a small Go service installed on a user-owned Linux server. It exposes a versioned JSON management API and reports system state. It does not own or proxy the user's application data.

Security defaults:

- the API listens on `127.0.0.1:7443` by default;
- a non-loopback listener is rejected unless TLS is configured;
- status data requires a 256-bit bearer credential;
- distinct device credentials are stored only as digests and can be revoked without restarting the agent;
- bearer comparisons use constant-time digest comparison;
- management responses are marked `no-store`;
- the systemd unit uses an unprivileged service account and operating-system hardening;
- the unauthenticated health endpoint exposes no system details.

## Bootstrap boundary

The current installer remains manual. It creates the shared development credential, installs a hardened systemd unit, and prints the initial token once. After independently verifying the SSH host key, the owner can explicitly enroll a named device through the agent CLI; only the credential digest is retained. For local development, the API can be reached through an SSH tunnel. A production remote connection requires trusted HTTPS.

The intended next bootstrap flow is:

1. The app authenticates to an existing Linux server over SSH.
2. The user verifies the SSH host identity.
3. The app installs and initializes the agent.
4. The agent enrolls the current app installation as a distinct trusted device.
5. Bootstrap credentials are discarded.
6. Subsequent management uses the revocable device credential.

The reviewed protocol and threat model are in [trusted-device-enrollment-protocol.md](trusted-device-enrollment-protocol.md). The agent-side enrollment and revocation slice is implemented, but the app does not automate SSH, persist credentials securely, or enroll a trusted certificate. It must not silently trust an unknown TLS certificate or permanently retain an SSH administrator credential.

## Validation Snapshot

As of August 26, 2026:

- the Windows management app has been manually tested with no failures reported;
- the Android management app has been manually tested with no failures reported;
- the Linux server agent has been manually tested with no failures reported;
- Linux desktop management-app validation remains deferred until a suitable Linux device is available;
- the complete app-to-agent SSH-tunnel workflow has not been separately confirmed in the test record.

These results validate the initial component scaffolding. They do not remove the version 0.1 development-token limitation or certify the system for production infrastructure.

## Deferred scope

- Windows Server agent and workload hosting;
- cloud-provider VPS creation;
- automatic SSH bootstrap and app-side secure credential storage;
- app/API device listing and revocation authorization;
- owner recovery and lost-all-devices behavior;
- service deployment;
- backup orchestration;
- edge-node orchestration.
