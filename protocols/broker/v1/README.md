# Core capability broker, version 1

Core owns enrollment and remote management sessions. Capability apps use
easyprivacy_core_sdk; no operation exports an enrollment seed, owner token,
transport private key or general signing function.

Android uses an explicit signature-protected Messenger service. Every message
checks the calling UID, publisher signature and package: Core itself, VPN, or
Files. Capability is derived from the package, rather than trusted input.
Desktop uses a protected per-user loopback registry and random control token;
this is a local-user boundary, not desktop executable authentication. No CORS
access is granted. Production signing/key rotation remains release work.

Requests contain protocol=1, capability, method and arguments. Replies contain
a result object or code/error. Control JSON is limited to 16 KiB of UTF-8,
16 pending operations and a 20-second deadline. Dispatched work retains its
slot until it settles, even after a reply times out.

| Caller | Operations |
| --- | --- |
| All | getSummary |
| Core | privateStatus, privateStart, privateStop, privateProbe, refreshGrants |
| VPN | vpnExits, vpnRegister(exit_id, public_key), vpnDisconnect, vpnStatus |
| Files | privateStatus, listServices, openStream(service_id), registerReceiver, acceptReceiver(receiver_id), closeReceiver(receiver_id) |

VPN/Files operations require explicit grants in Core. Core starts/stops the
private transport; Files cannot enable it or choose arbitrary IPs, ports or
routes. Discovery resolves service IDs against the current node response before
issuing a stream. Disabling Files access invalidates pending work/tickets,
closes active Files streams and removes the receiver. The UI notifies the
broker immediately; its background grant check is a fallback.

## Stream protocol

Payload bytes travel through pinned loopback TLS 1.3 sockets, outside JSON RPC
and Android Binder. The native runtime holds the WireGuard userspace netstack;
it creates no OS TUN or default route. Stream tickets contain protocol=1,
loopback port, SHA256 certificate pin, a random 256-bit ticket and expires_at.
Tickets are single use, expire after 30 seconds and are bound to a capability.
The server retains hashes of tickets, with at most 32 outstanding.

The SDK verifies the ephemeral local certificate and sends one newline-delimited
JSON object with protocol=1 and ticket. The server replies with byte 0 on
success or 1 on rejection, then relays the full-duplex byte stream. The SDK
preserves data coalesced with that first byte. Neither the ticket nor the local
control token authorizes a remote node session.

Receivers use TCP 41931 inside WireGuard. An outbound receiver stream begins
with EPPR1 and the 32-character receiver lease ID. A stale address/lease cannot
silently deliver bytes to a replacement receiver. acceptReceiver waits up to
eight seconds, returning waiting=true or a one-time incoming stream ticket.
Receiver queues hold four connections. There are at most 16 native active or
pending streams, four native listeners and 32 local TLS connections.

Core launches the packaged helper using an anonymous stdin/stdout control pipe;
keys are not command arguments or registry contents. EOF shuts it down.
Android packages the PIE executable as an extracted APK native library and keeps
the hosting broker in a connected-device foreground service while enabled.
The optional EasyPrivacy VPN excludes Core's Android UID so Core's encrypted
outer connection remains independent of that Internet tunnel. Other VPN apps'
blocking/lockdown policies and physical-device recovery still require testing.
