# Windows application bundles

Keep each Windows ZIP's contents together in its own application folder. The
packager includes a distinct top-level folder for each app:

| Folder | Application to open |
| --- | --- |
| EasyPrivacy Core | `easyprivacy.exe` |
| EasyPrivacy VPN | `easyprivacy_vpn.exe` |
| EasyPrivacy Files | `easyprivacy_files.exe` |

Each executable needs its adjacent `data` directory and DLLs. The three bundles
all use `data/app.so` and overlapping asset names, with different contents.
Combining the contents of their folders overwrites application code. Moving only
the executables also breaks the bundles. Older ZIPs omit the top-level folder;
extract those into separate folders yourself.

Core and Files communicate through a per-user broker under
`%APPDATA%\EasyPrivacy\Core`. They do not need to be in the same parent directory.
Open Core, connect it, and enable Files under Connected applications before using
Files. Use the same Windows account for both apps.

If Files says to open Core even though it is connected, first close Files and
reopen it from a complete Files bundle. If the error persists, the Windows Files
executable supports a diagnostic command in PowerShell:

```powershell
$files = 'C:\path\to\EasyPrivacy Files\easyprivacy_files.exe'
$report = Join-Path $env:TEMP 'easyprivacy-files-diagnostic.json'
Start-Process -FilePath $files -ArgumentList ('--diagnose-core="'+$report+'"') -Wait
Get-Content -LiteralPath $report
```

The command exits after recording the executable and broker paths, whether the
broker registry exists, and the result of read-only Files session/private-status
requests. It does not record the broker token, pairing secrets, or private keys.
Run it as the same Windows user as the affected Files instance. It checks a fresh
process; success cannot establish what happened inside an earlier instance.

On October 24, 2026, a Desktop Files instance reported a missing broker while
Core's broker was healthy. A freshly built complete Files bundle at the same
Desktop location passed these diagnostics and displayed the connected Core after
relaunch. The original instance's failure was not isolated. Combining the app
bundles was a later troubleshooting attempt, so it does not explain the initial
error.
