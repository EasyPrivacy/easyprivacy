# Private Drive

Drive stores authoritative files on an always-on Linux storage node. It pairs
with Core using its own revocable identity and an outbound private WireGuard
connection. It can run beside Core or on another machine; no public storage
port or Internet VPN is required. Files uses Core's granted private streams.

The first implementation supports named, independent storage locations on one
node. Each location is an existing mounted drive/directory or a newly created
folder, with an application-enforced byte limit. Upload reservations prevent
concurrent clients from exceeding that limit. Direct writes by other software
are outside that quota mechanism. Existing data is preserved and counted.

Clients browse metadata and explicitly upload, preview or download content.
Uploads never remove or watch their originals. Downloads are independent local
copies. Cloud deletion never removes those copies. No automatic cloud-to-client
replication, RAID, secondary-node replication or redundancy is included.

The server uses confined filesystem handles, rejects linked/special files,
publishes uploads atomically after length/hash validation, and refuses a missing
or replaced storage root. Configuration and enrollment are separate from file
contents. A logical volume ID is independent of its backing path for later
storage/replication work; the first client shows locations individually.

Every request has a short-lived, nonce-protected, operation-specific device
signature issued by Core's Files broker. The storage node checks current paired
device authorization with the pinned Core before accepting an operation. Core
remains trusted with private transport traffic. This is not client-side encrypted
cloud storage. Existing Send/Sync encryption and behavior stay independent.

## Install the candidate

This candidate uses node package **1.0.1~reorg4**, Core **1.0.0+11** and Files
**1.0.0+7**. The storage-node role currently runs on Ubuntu 24.04 amd64/arm64.
Windows and Android are Drive clients. Node installation does not start Drive
until the administrator configures it. No changes are deployed automatically.

1. Upgrade the existing core node with the matching architecture package:

   ```bash
   sudo apt install ./easyprivacy-node_1.0.1~reorg4_amd64.deb
   ```

   This updates its management and network helper together. Keep its existing
   configuration; do not repeat Core's `setup`. The existing private network
   remains a prerequisite. A new Core deployment enables that network with
   `sudo easyprivacy-node network-setup`.

   An existing Core running reorg2 already supports the Drive protocol. Apply
   reorg4 on the Drive VM for both the Linux service-sandbox and session-reuse
   fixes. Updating an existing Drive VM does not require repeating setup.

2. Install Core build 11 and Files build 7 over the existing client apps. Their
   enrollment, grants and Sync settings are retained. Windows candidate ZIPs
   contain distinct `EasyPrivacy Core` and `EasyPrivacy Files` directories;
   preserve the complete bundles. Do not combine their runtime files.

3. On the machine that will store the data, install the same node package, then:

   ```bash
   sudo easyprivacy-node drive-setup
   ```

   This can be the Core VPS or another Linux machine. The wizard asks for Core's
   management address, a Drive node name, a fresh pairing code, account username,
   storage directory, maximum GiB and a hidden account password. Obtain the code
   from Core's Add device or `sudo easyprivacy-node pair` on the Core server.
   The node verifies Core before sending the password; only its enrolled device
   identity and private transport key are saved. A failed storage configuration
   preserves enrollment, and repeating `drive-setup` resumes storage setup.

   The default `/srv/easyprivacy-drive` is created as a private folder if absent.
   For storage on a mounted drive, create a new data folder first, for example:

   ```bash
   sudo install -d -o easyprivacy-drive -g easyprivacy-drive -m 0700 /mnt/storage/cloud
   ```

   Select `/mnt/storage/cloud` in setup. Mount the actual disk first. To use the
   mounted drive's root or an existing directory, the administrator must give
   `easyprivacy-drive` ownership and appropriate access to the directory and its
   contents. Setup never formats a disk or recursively changes existing data's
   ownership. It checks filesystem support for atomic uploads. Configuration
   stays under `/var/lib/easyprivacy-drive`, separately from the cloud files.

4. In the client Core app, enable its **Private service connection** and allow
   Files under **Connected applications**. The management connection alone does
   not start this private transport; the full Internet VPN is optional.
   Open Files > Drive and refresh. Select the node and storage location, then
   upload a disposable file. The server runs as `easyprivacy-drive`, without
   network administration privileges. Its systemd sandbox grants writes only
   to its configuration and the selected data directories.

Additional independent locations on the same node use:

```bash
sudo easyprivacy-node drive-volume-add --name Photos --path /mnt/photos/cloud --quota-gib 200
sudo easyprivacy-node drive-status
sudo journalctl -u easyprivacy-drive --since today
```

`drive-volume-add` restarts the Drive service to apply the new location. Use
`sudo easyprivacy-node drive-stop` / `drive-start` to control it. Revoke its
paired-device identity in Core to remove private access. Uninstalling/purging
the package preserves storage and enrollment. Existing volume markers can be
reused when an administrator explicitly chooses that storage directory again.

## Connection troubleshooting

If Files reports **No Drive node is available**, check Core's Private service
connection on that client, Files access, and Core build 11 / Files build 7.
Restarting or updating Core can leave the private connection stopped. Files'
current empty-state message does not distinguish that condition from an empty
server service list.

If the node is listed but Files reports **The private service did not accept the
connection**, inspect `sudo journalctl -u easyprivacy-drive --since today` on
the storage VM. `drive-status` reporting `active: true` means the service process
is running; it does not independently verify its private connection.

Node reorg2 omitted `AF_NETLINK` from the Drive service's permitted socket
families. Linux userspace WireGuard requires an unprivileged `NETLINK_ROUTE`
socket. This caused repeated `Drive private connection unavailable; retrying`
messages even though enrollment, storage and the receiver advertisement existed.
Install reorg4 on the Drive VM and restart `easyprivacy-drive`; enrollment and
files are retained. The fix retains the dedicated service user and empty
capability set. Existing reorg2 Core servers and client builds 11/7 remain compatible.

If browsing or uploading alternates between authorization errors and connection
failures, update the Drive VM to reorg4. Earlier Drive builds signed into Core
for every device lookup, including both upload checks and periodic lease renewal.
Core permits ten sign-in requests per IP each minute; one device login consumes
two requests. Ordinary browsing could exhaust that budget, reject an upload's
final check and interrupt the private transport on its next renewal.

Reorg4 shares one synchronized, in-memory authenticated session across those
requests, renews it once on expiration, and backs off failed sign-ins. Every file
operation and upload publication still fetches current device authorization;
paired-device permissions and public keys are never cached. Core's existing rate
limit is unchanged. After installing, allow up to a minute for a previously
exhausted sign-in window to clear, then refresh Drive and retry the upload.

## Current limits

- Up to eight independent storage locations per node; clients select a location.
  They are not pooled into one merged namespace in this version.
- A 1 GiB limit per file, 100,000 entries per location and 128 entries per
  directory page. Transfers have a ten-minute server deadline. An interrupted
  transfer is retried from the beginning; resumable uploads are future work.
- Existing filenames must be portable across supported clients. Linked files,
  special files, reserved device names and Drive's metadata directory are not
  exposed. A filesystem with hard-link support is required for atomic uploads.
- In-app previews support common raster images up to 16 MiB and text up to
  1 MiB. Other formats can be downloaded and opened in another application.
- Downloads/previews use a bounded-memory, checksum-verified private temporary
  copy before saving through the system picker. Saving leaves a separate local
  file. Temporary copies are discarded after the action; abandoned copies older
  than 24 hours are cleaned on a subsequent download.
- Uploading an existing cloud name is rejected; rename/move the existing item
  or choose another name. This version has no overwrite history, trash, public
  sharing links, per-household roles, RAID configuration or replica-node setup.
- All configured locations must be available at server startup. A missing or
  replaced location during operation causes its requests to fail, preserving
  the original directory and data. Startup retries until storage is available.

Capacity is an upper bound on bytes accepted by Drive, not a filesystem space
reservation. Existing ordinary files count toward usage; direct administrative
writes bypass upload reservations. Other software can exhaust physical free
space, in which case an upload fails without publishing a partial file.

## Protocol and code ownership

- `core/internal/drive`: scoped signatures, replay checks, framed streaming,
  confined storage, reservations, atomic upload publication and metadata pages.
- `core/cmd/easyprivacy-node/drive.go`: enrollment, setup, storage locations,
  service lifetime, current authorization lookup and private WireGuard listener.
- `core/internal/vpn/private_access.go`: Drive receiver discovery/renewal using
  the existing private receiver port and firewall grants.
- `packages/easyprivacy_protocol/lib/src/drive.dart`: canonical signed command.
- `apps/core/lib/runtime/broker/core_broker_runtime.dart`: Files-granted,
  operation-specific signing for an advertised, paired Drive node.
- `apps/files/lib/drive` and `lib/screens/drive_screen.dart`: explicit transfers,
  metadata browsing, quota display, previews, cancellation and cloud file actions.

See [Drive wire protocol](../protocols/drive/v1/README.md) for framing and scope.

## Verification

Go tests cover concurrent capacity reservations, partial/corrupt upload rejection,
no silent overwrites, restart, moved/replaced roots, symlink/traversal rejection,
pagination, revoked-device rejection, replay and operation tampering. A shared
Unicode claim vector verifies Dart/Go canonical byte agreement. The real Dart
client runs against the Go server with two synthetic enrolled identities and
checks metadata-only browsing, independent upload/download copies, moves,
deletion, quotas, corrupt uploads and cancellation. The phone-width widget test
checks layout and explicit cloud-deletion approval.

The Core API regression reproduces the old sixth-login rate-limit failure. It
then verifies concurrent device checks and lease renewals share one login,
concurrent session expiry causes one renewal, target/node revocation is still
enforced, repeated metadata browsing does not block an upload, and revocation
between an upload's initial check and publication discards its data and quota.

`core/scripts/test-drive-sandbox.sh` runs the native private transfer, verified
receipt, ticket-replay and revocation check under the unit's actual non-path
sandbox settings as `nobody`, with no capabilities. Its negative control
reproduces the previous missing-NETLINK startup failure. Build its test binary
from `core/`, then run the sandbox script as root on a systemd Linux test host:

```bash
go test -c -o ../.tools/drive-runtime-sandbox.test github.com/easyprivacy/easyprivacy/core-runtime
cd ..
sudo bash core/scripts/test-drive-sandbox.sh .tools/drive-runtime-sandbox.test
```

The owner confirmed the separate storage VM appeared and opened from Android
after starting the client's private connection and applying the service socket
family fix, then reported Android Drive works after the reorg4 authentication fix.
The installed Windows Core/Files bundles also passed live read-only discovery,
capacity and folder-listing checks. Independent physical upload/download hashes,
Android save-picker access, local-copy retention and long-running operation still
require testing.
