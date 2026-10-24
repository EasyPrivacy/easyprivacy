# Files Send: first implementation

Requires Core 1.0.0+10 and Files 1.0.0+2 on both devices, paired to the same node.
The existing 1.0.1~reorg1 node package already provides the necessary APIs.

## Using Send

1. In Core, enable Files access and start the private connection.
2. Open Files on the recipient and enable Receive files. Keep Files open on both
   devices for the transfer. An Internet VPN is optional.
3. On the sender, choose the receiving device and Choose file and send.
4. The recipient sees the authenticated paired-device name, filename and size.
   Accept file permits receipt into Files' private storage; Decline sends no payload.
5. Both sides show progress. Verified on the sender means the recipient checked
   the full SHA-256 and returned an encrypted completion receipt.
6. Use Save a copy on the recipient to choose a destination. Android uses the
   system document picker without broad storage permissions. Desktop asks before
   replacing an existing file. Saving successfully removes the app's retained copy.

Send handles one active transfer at a time per app. Other devices must have Files
receiving enabled; offline payload storage/forwarding is not provided. Folder
Sync is implemented in Files 1.0.0+3; see [Files Sync](files-sync.md). Drive remains
unavailable.

## Retry, storage and cancellation

Each transfer uses a deterministic ID derived from the core, sender/recipient
identities, safe filename, size and SHA-256. A network failure retains a partial
on the recipient. Retry starts a fresh authenticated connection and requests the
existing byte offset; the recipient rehashes the prefix and verifies the complete
file. A source that changes cannot produce a verified receipt. After a sender
restart, selecting the same file again derives the same transfer ID and resumes.
There is no automatic retry loop and no automatic reconnect after an OS kill.

Cancelling sends an authenticated cancellation when possible and removes the
recipient partial. If the connection is already broken, cancellation cannot
reach that peer; its partial remains subject to expiry or Remove copy. A local
receiver cancellation removes its own partial. A retained completed file can be
re-acknowledged after a lost receipt without appending or duplicating its data.

Received and partial copies live under the app's private easyprivacy-send
directory, using random-looking IDs and fixed internal payload names. Remote
filenames never become internal paths. At most eight copies are retained; the
owner must save/remove one before accepting more. Copies older than 24 hours
from acceptance are cleared when Files opens or accepts another file. This is
cleanup on use, not a guarantee of deletion while the app is stopped. Save copies
needed permanently. Android's native file picker also stages selected source
files in its app cache; Android controls cache eviction. Outgoing jobs are kept
only in memory. Sender originals and exported destination files are independent
of retained-copy cleanup.

Files reads/writes payloads in chunks of at most 64 KiB. The initial maximum
declared size is 1 TiB; this is a validation bound, not a tested storage/performance
claim. Hash preparation reads the source before sending and can take time for
large files. Disk failures stop the transfer and cannot return verified success.

## Engine decision

[croc's current client](https://github.com/schollz/croc/blob/main/src/croc/croc.go)
was evaluated before implementation. It offers encrypted transfers and resume,
but exposes relay/local/multiplexed connection options rather than a supplied
Core byte stream. Embedding it unchanged would add independently managed network
paths. This slice therefore uses a narrow SendEngine behind
providers/device_transfer_provider.dart; no croc code or public relay is bundled.
A future adapter can replace this engine while retaining the UI/provider boundary.

Cryptographic operations use the existing
[cryptography 2.9.0 library](https://pub.dev/packages/cryptography): Ed25519,
X25519, HKDF-SHA256 and AES-256-GCM. The native file selection plugin is
[file_selector](https://pub.dev/packages/file_selector); selected files are read
as streams. This is a new application protocol, not an audited croc adaptation.
Independent protocol/security review remains a production gate.

## Authentication and encrypted records, version 1

Core exposes only filesDevices and filesHandshake in addition to the existing
Files stream operations. The latter accepts an enrolled peer, ephemeral X25519
public key, random 256-bit session nonce and sender/receiver role. Core fixes its
own device ID, enrolled core fingerprint and two-minute expiry and signs the
exact domain-separated claim in easyprivacy_protocol/src/files.dart. It returns
only public identity, claim fields and signature. The Files grant is rechecked
before issuance. It cannot sign arbitrary messages or export enrollment material.

Both Files endpoints verify the Ed25519 signature, the hash of that public key
against the expected device ID, core fingerprint, intended peer, session nonce,
role and expiry. The receiver also checks current paired-device membership.
Fresh X25519 keys provide a shared secret. HKDF uses the SHA-256 of both canonical
signed handshakes as salt and separate sender/receiver domain labels to derive
directional 32-byte AES keys. All-zero shared secrets are rejected.

Every frame starts with a four-byte big-endian length, bounded to 64 KiB + 64.
Initial handshake frames contain public JSON only. After key agreement, AES-GCM
encrypts a record type byte and its payload; the 16-byte MAC follows ciphertext.
Each direction has its own increasing 64-bit counter in a 12-byte nonce and stops
before 2^32 records. Associated data binds the transcript hash and nonce. Writes
are serialized. There is no compression or plaintext fallback.

Encrypted control JSON is limited to 4 KiB: ready/key confirmation, offer,
accept(offset), decline, finish(SHA-256), complete(id, SHA-256) and cancel.
Payload records carry at most 64 KiB. Approval waits at most four minutes at the
recipient/five at the sender; frame reads and writes otherwise time out after
30 seconds. Local Core stream tickets/pins still protect the cross-app byte handoff.

The core node can observe membership, connection endpoints, timing and sizes,
but relayed file metadata and payload are encrypted between Files endpoints.
Core remains the enrollment/membership authority; trusting a newly listed device
or display name is not independent verification of a compromised authority.
Local Core and the device OS remain trusted. This does not claim anonymity,
protection after endpoint compromise, or replacement for disk encryption.

## Validation and next gates

70 ordinary workspace tests, formatting, analysis and import boundaries passed.
Real-socket tests verify empty/one-byte/8 MiB transfers, full-file receipts,
interruption/resume, decline, local/remote cancellation, modified sources, AEAD
corruption, malformed metadata, unsafe filenames, retention and delegation scope.
Android and Windows Core/Files release builds passed.

On the connected Pixel, the normal Files app accepted an 8 MiB offer from the
laptop, saved it through Android's system dialog, then selected it through the
native picker and sent it back. Both directions passed full-file integrity and
completion receipts. The laptop used the production provider in the opt-in test
below. The native Windows picker, physical interruption/resume, very large files,
background/OS-kill handling and the new protocol's independent security review
remain further checks. No new Internet/DNS/IPv6 leak result is implied.

From apps/files on Windows, with the phone ready to receive:

```powershell
$env:EP_PHYSICAL_SEND_TEST = '1'
$env:EP_SEND_MODE = 'send'
flutter test --no-pub test/physical_send_test.dart --reporter expanded
```

Accept only the generated easyprivacy-send-test-* offer on the phone. To send
that file back, set EP_SEND_MODE to receive and rerun. The harness accepts only
that filename prefix and 8 MiB size, verifies the fixture hash and removes its
temporary receiver/files afterward. Remove the environment variables after use.
Normal workspace checks skip physical tests. Serialize Android builds with other
Flutter jobs that regenerate shared plugin metadata; a concurrent test/pub-get
can otherwise race the release plugin registrant.
