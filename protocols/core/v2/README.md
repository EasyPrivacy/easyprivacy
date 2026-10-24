# Private-network API

Existing v1 enrollment and Internet/Home VPN endpoints remain compatible.
All v2 operations require an enrolled device session. The node chooses the
parent device, address, route, ports and receiver lifetime; callers cannot
supply those values.

| Method | Path | Request |
| --- | --- | --- |
| POST | /api/v2/network/private/peer | public_key |
| GET | /api/v2/network/private/status | none |
| POST | /api/v2/network/private/disconnect | none |
| GET | /api/v2/network/private/services | none |
| POST | /api/v2/network/private/receiver | capability: files |
| POST | /api/v2/network/private/receiver/disconnect | none |

Registration returns protocol=1, public_key (core traffic key), endpoint,
address (/32), subnet (private /24), mtu=1280, keepalive=25, and a probe target.
Core generates and retains its own private traffic key, independently of the
optional Internet VPN application's key.

Discovery returns protocol=1 and services: core.probe plus other enrolled
devices' active Files receivers. Targets contain id, name, address and port;
receivers also have device_id and expires_at. Receivers are not listed to their
own parent device. There is one lease per device, at most 16 receivers, and a
120-second lifetime. Core renews a receiver every 30 seconds while authorized.
Helper restart clears receiver leases; expired/revoked leases fail closed.

The helper permits private members to reach TCP 41930 on the core's overlay
address for a bounded 32-byte nonce echo. TCP 41931 forwarding is permitted
only from another private member to an actively leased Files receiver, with
stateful return traffic. Other forwarding and core-local access are dropped.
Internet/Home peers do not inherit these grants. Ports 41930/41931 are internal
overlay services; do not expose them in the public firewall.

Independent private-services and legacy Internet/Home records share an enrolled
parent. Keys and addresses cannot be reused across records. Either connection
can disconnect independently. Parent revocation removes all its records and
receiver grants. The core relays the two WireGuard legs and is trusted with
forwarded bytes; application-level end-to-end file encryption remains future work.

network-setup creates schema-2 private-only configuration with no Internet NAT,
uplink or DNS configuration. vpn-setup can later enable an Internet exit while
preserving keys, endpoint and subnet. Existing schema-1 Internet installations
retain their existing behavior when upgraded or when network-setup is invoked.

Before the first purpose-aware peer write, peers.pre-private.json retains the
legacy peer state. An older helper cannot parse purpose-aware records. Stop
the new helper before rollback and restore the legacy snapshot/configuration;
see [upgrade and rollback](../../../docs/private-network-upgrade.md).

The API and byte-stream foundation are implemented. Files Send, Sync and Drive
engines and general hosted-service installation are subsequent work.
