# EasyPrivacy Files

An independently installable Files application using Core's authorized private
streams. The current build supports Android ARM64 and Windows x64.

Files 1.0.0+5 provides [approved, encrypted Send](../../docs/files-send.md) and
[live folder Sync](../../docs/files-sync.md) through Core. Windows syncs chosen
folders directly. Android manages folders under Documents/EasyPrivacy Files after
an owner-granted directory permission. Recipients can choose selective sync;
background operation is opt-in on both platforms. The source always stays complete.

Real-engine and synthetic document-adapter checks passed. Physical validation of
the new Android Documents and background workflow remains pending owner testing.
The previous app-private Sync workflow passed phone/laptop checks in builds 3/4.
Drive remains unavailable; no cloud server is installed.

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
