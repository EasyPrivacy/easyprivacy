param([ValidateSet('windows-x64')][string]$TargetPlatform='windows-x64')
$ErrorActionPreference='Stop'
$projectRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest=Get-Content -LiteralPath (Join-Path $projectRoot 'native/sync-engine/upstream.json') -Raw|ConvertFrom-Json
$cache=Join-Path $projectRoot '.tools/syncthing'
New-Item -ItemType Directory -Force -Path $cache|Out-Null
$archive=Join-Path $cache ('windows-'+$manifest.version+'.zip')
if(-not(Test-Path -LiteralPath $archive)){Invoke-WebRequest -Uri $manifest.windowsUrl -OutFile $archive}
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.windowsSha256){throw 'Sync engine checksum mismatch.'}
$staging=Join-Path $cache ('windows-'+$manifest.version)
Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
$binary=Get-ChildItem -LiteralPath $staging -Filter syncthing.exe -Recurse -File|Select-Object -First 1
if(-not $binary){throw 'Missing Sync engine in archive.'}
$destination=Join-Path $projectRoot 'apps/files/native/windows'
New-Item -ItemType Directory -Force -Path $destination|Out-Null
Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $destination 'easyprivacy-sync.exe') -Force
Write-Output ('Built Files Sync engine '+$manifest.version+' for Windows x64.')
