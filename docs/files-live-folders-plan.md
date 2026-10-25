# Live folder Sync implementation

Requested October 24, 2026. This replaces the initial app-private folder workflow.

## Behavior

- Windows attaches an existing source directory, including its descendants.
  A receiving Windows device chooses its own local directory when accepting.
- Android requests a persistent Storage Access Framework grant to Documents and
  creates `EasyPrivacy Files/<shared folder name>` within it. Users can edit the
  public copy directly. A journaled adapter connects this document tree to the
  bundled engine's private filesystem without all-files storage permission.
- Edits, additions, renames and deletions propagate automatically. The originating
  device can invite multiple paired devices to the same folder. Its engine
  forwards changes between those replicas while it is available.
- Each receiving device selects everything or a local selection. The app browses
  the engine's global index to show names without downloading all file contents.
  Ignore rules enforce the selection before a folder begins receiving data.
  Removing a selected local copy must not become a deletion on another device.
- Files has add, folder creation, move, open/edit and delete actions. External
  changes are reflected by the engine watcher and an automatically refreshed view.
- Background operation is opt-in: Windows keeps a tray icon with Open/Quit;
  Android keeps the same engine alive in a connected-device foreground service
  with an ongoing notification. Existing Core grants/private connectivity remain
  prerequisites. Android force-stop and OS shutdown still stop the application.

## Organization

- `lib/sync/sync_paths.dart`: relative path confinement, selection rules, entries.
- `lib/providers/folder_sync_provider.dart`: persisted locations and peer grants,
  invitations, local policy, catalog and file operations. Migrate version 1 state.
- `lib/sync/sync_engine.dart`: explicitly authorized external roots, multiple
  peers, global index browsing and selection policy before unpausing folders.
- `lib/sync/documents_mirror.dart`: three-way Documents reconciliation and journal.
- `lib/screens/sync_screen.dart`: directory selection, receiving location, policy,
  folder browser and device invitation actions.
- `lib/background/`: persisted preference and background platform coordination.
- Android native Files host/storage/service: persistent document grants, bounded
  streaming document operations, app chooser, retained Flutter engine, notification.
- Windows Files runner: single instance, file app chooser, folder open, tray lifetime.

## Validation

Use synthetic external directories and real pinned engines to verify nested
changes, multiple receivers, selections, selective eviction without remote
deletion, unavailable roots, restart, conflict preservation and stop sharing.
Exercise traversal/symlink confinement and non-destructive state migration.
Validate Android document access and background lifecycle on the physical phone;
validate the Windows UI and tray from a complete release bundle. Existing Send
and private bridge tests must continue to pass. Keep untested platform behavior
explicit in the progress record.
