# EasyPrivacy Files

An independently installable Files application using Core's authorized private
streams. The current build supports Android ARM64 and Windows x64.

Files 1.0.0+7 provides [approved, encrypted Send](../../docs/files-send.md),
[live folder Sync](../../docs/files-sync.md) and a [hosted Drive candidate](../../docs/files-drive.md)
through Core. Windows syncs chosen
folders directly. Android manages folders under Documents/EasyPrivacy Files after
an owner-granted directory permission. Recipients can choose selective sync;
background operation is opt-in on both platforms. The source always stays complete.

The owner verified automatic Sync updates, selective local copies and deletion
between Windows and Android after the build 6 location fix. Extended background
testing remains pending.

Drive browses a separately configured Linux storage node, with explicit uploads,
downloads, text/image previews and cloud file actions. Uploading keeps the local
original; browsing does not create synced copies. Core build 11 and node package
1.0.1~reorg2 or later on Core are required; use reorg4 on the Drive storage VM
for its corrected Linux service sandbox and authenticated session reuse.
Local server/client checks passed, and
the owner confirmed Android can open the separate storage node. Physical file
transfer and save-picker validation remain pending. Follow the Drive guide above.

From the repository root:

```powershell
    flutter pub get
    # Build the ARM64 engine in WSL using tool/build-sync-engine.sh first.
    ./tool/build-sync-engine.ps1
    ./tool/build-android.ps1 -App files
    ./tool/build-windows.ps1 -App files
```

The Linux app scaffold remains in the repository; its packaged engine lookup and
end-to-end Files integration have not been validated.

See [Windows app folders and troubleshooting](../../docs/windows-apps.md) before
extracting the desktop bundles. Each app needs its own complete runtime folder.
