$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseVersion = (Get-Content -Raw -LiteralPath (Join-Path $appRoot '../VERSION')).Trim()
if ($releaseVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid project VERSION.' }
Push-Location $appRoot
try {
    flutter build apk --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
    $apk = Join-Path $appRoot "build/easyprivacy-android-$releaseVersion.apk"
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination $apk -Force
    $checksum = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    "$checksum  $([IO.Path]::GetFileName($apk))" | Set-Content -LiteralPath ($apk + '.sha256') -Encoding ascii
    Write-Output "Android APK: $apk"
} finally { Pop-Location }
