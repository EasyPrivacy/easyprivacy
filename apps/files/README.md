# EasyPrivacy Files

An independently installable Files application using Core's authorized private
streams. The current build supports Android ARM64 and Windows x64.

Files 1.0.0+4 provides [approved, encrypted Send](../../docs/files-send.md) and
[two-device folder Sync](../../docs/files-sync.md) using bundled Syncthing
through Core. Both need Files open. Send has passed actual phone/laptop transfers;
Sync has passed real-engine bridge tests and physical phone/laptop checks.
Sync initially owns its folders inside Files rather than synchronizing arbitrary
Android document trees. Drive remains unavailable; no cloud server is installed.

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
