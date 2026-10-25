# Private Drive stream protocol v1

Discovery advertises `kind=drive` on an ordinary leased `receiver.<32 hex>`
target. Core's native bridge supplies the existing `EPPR1` + lease ID preface
on TCP 41931 inside WireGuard. There is no public storage listener. A stream
then carries one Drive operation before closing.

Frames are four-byte unsigned big-endian JSON lengths followed by UTF-8 JSON.
Requests are limited to 8 KiB and response metadata to 64 KiB. Contents are raw,
length-delimited bytes outside metadata/Binder/RPC. Commands contain exactly
`op`, `volume`, `path`, `target`, `cursor`, `size`, `sha256`. Supported operations
are `volumes`, `list`, `upload`, `download`, `mkdir`, `move`, `delete`.

The request frame is an authorization envelope with `command`, `core`, `device`,
`node`, `nonce`, `expires`, `identity` and `signature`. Identity/signature use
standard Base64. Device and node IDs are 64 lowercase hex characters. The nonce
is 32 random bytes as lowercase hex; expiry is Unix seconds. Core supplies its
own fingerprint/device, fixes a two-minute lifetime and signs only after checking
the Files grant, paired target and active Drive advertisement.

Exact Ed25519 claim bytes (no trailing newline):

```text
EasyPrivacy Drive request v1
<Core SHA256 fingerprint, uppercase digest>
<requesting device ID>
<storage node device ID>
<operation>
<volume ID or empty>
<Base64 UTF-8 path>
<Base64 UTF-8 move destination or empty>
<Base64 UTF-8 directory cursor or empty>
<upload length in decimal, otherwise 0>
<upload SHA256 lowercase hex, otherwise empty>
<nonce lowercase hex>
<expiry decimal Unix seconds>
```

The storage node checks identity hash, signature, node/Core binding, expiry and
replay. It fetches current device authorization from pinned Core management
before accepting an operation, and checks authorization again before publishing
an upload. A used nonce cannot authorize another operation. All paired devices
currently belong to the same owner; more granular remote roles are deferred.

Upload sends the signed envelope, waits for `status=ready` after capacity is
reserved, then sends exactly `size` bytes. The server verifies SHA256, synchronizes
the file and atomically publishes it without replacing another name. It responds
with `status=ok` and SHA256. Aborts release reserved capacity and staging bytes.

Download responds with `status=ok` and `entry` (name/directory/size/modified),
followed by exactly that size of raw bytes and another frame with `status=ok`
and SHA256. Clients publish only a completed, verified temporary copy. Metadata
operations return `status=ok` plus volumes or entries/next cursor as appropriate.
Errors return `status=error` and a bounded user-facing error; no payload follows.

Network paths are relative POSIX paths. Root is allowed only for listing;
components are limited to 180 UTF-8 bytes, paths to 2,048 bytes and 64 components.
Traversal, controls, links, platform-reserved names and `.easyprivacy-drive`
are rejected. A volume ID never permits selecting arbitrary server paths.

WireGuard protects the client/Core and Core/storage legs. Core is trusted with
the transit plaintext; this protocol does not claim client-side content encryption.
