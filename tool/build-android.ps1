param(
    [ValidateSet('core','vpn','files')][string]$App = 'core',
    [switch]$Debug,
    [ValidateSet('android-arm','android-arm64','android-x64')]
    [string[]]$TargetPlatform = @('android-arm','android-arm64','android-x64')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appRoot = Join-Path $repoRoot "apps/$App"
if ($App -eq 'files' -and -not $PSBoundParameters.ContainsKey('TargetPlatform')) {
    $TargetPlatform = @('android-arm64')
}
$TargetPlatform = @($TargetPlatform | Select-Object -Unique)
$platformAbis = @{
    'android-arm' = 'armeabi-v7a'
    'android-arm64' = 'arm64-v8a'
    'android-x64' = 'x86_64'
}
if ($App -eq 'core') {
    foreach ($platform in $TargetPlatform) {
        $abi = $platformAbis[$platform]
        $pairing = Join-Path $appRoot "android/app/src/main/jniLibs/$abi/libeasyprivacy_pairing.so"
        if (-not (Test-Path -LiteralPath $pairing)) { throw "Build the Core pairing library for $abi with tool/build-pairing.ps1 before packaging." }
        $runtime = Join-Path $appRoot "android/app/src/main/jniLibs/$abi/libeasyprivacy_core_runtime.so"
        if (-not (Test-Path -LiteralPath $runtime)) { throw "Build the Core private runtime for $platform with tool/build-core-runtime.sh before packaging." }
    }
}
if ($App -eq 'files') {
    if (@($TargetPlatform | Where-Object { $_ -ne 'android-arm64' }).Count -ne 0) {
        throw 'Files Sync currently supports Android ARM64 only. Use -TargetPlatform android-arm64.'
    }
    foreach ($platform in $TargetPlatform) {
        $syncEngine = Join-Path $appRoot "android/app/src/main/jniLibs/$($platformAbis[$platform])/libeasyprivacy_sync_engine.so"
        if (-not (Test-Path -LiteralPath $syncEngine)) { throw "Build the Files Sync engine for $platform before packaging." }
    }
}
Push-Location $appRoot
try {
    $mode = if ($Debug) { 'debug' } else { 'release' }
    flutter build apk "--$mode" ("--target-platform=" + ($TargetPlatform -join ','))
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
    if ($App -eq 'files') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $appRoot "build/app/outputs/flutter-apk/app-$mode.apk"))
        try {
          if (@($zip.Entries | Where-Object { $_.FullName -match '^lib/(?!arm64-v8a/)' }).Count -ne 0) { throw 'Files APK advertises an unsupported native architecture.' }
          foreach ($platform in $TargetPlatform) {
            $entry = $zip.GetEntry("lib/$($platformAbis[$platform])/libeasyprivacy_sync_engine.so")
            if ($null -eq $entry -or $entry.Length -eq 0) { throw "Files APK is missing the Sync engine for $platform." }
            $stream = $entry.Open()
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $actual = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
            finally { $stream.Dispose(); $hasher.Dispose() }
            $source = Join-Path $appRoot "android/app/src/main/jniLibs/$($platformAbis[$platform])/libeasyprivacy_sync_engine.so"
            if ($actual -ne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) { throw 'The packaged Sync executable differs from the verified native artifact.' }
        }} finally { $zip.Dispose() }
    }
    if ($App -eq 'core') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $apkPath = Join-Path $appRoot "build/app/outputs/flutter-apk/app-$mode.apk"
        $zip = [IO.Compression.ZipFile]::OpenRead($apkPath)
        try {
            foreach ($platform in $TargetPlatform) {
                $entry = $zip.GetEntry("lib/$($platformAbis[$platform])/libeasyprivacy_pairing.so")
                if ($null -eq $entry -or $entry.Length -eq 0) { throw "Core APK is missing its pairing library for $platform." }
                $runtimeEntry = $zip.GetEntry("lib/$($platformAbis[$platform])/libeasyprivacy_core_runtime.so")
                if ($null -eq $runtimeEntry -or $runtimeEntry.Length -eq 0) { throw "Core APK is missing its private runtime for $platform." }
            }
        } finally { $zip.Dispose() }
    }
    $version = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'VERSION')).Trim()
    $platformSuffix = if ($TargetPlatform.Count -eq 3) { '' } else { '-' + (($TargetPlatform | ForEach-Object { $_.Replace('android-', '') }) -join '-') }
    $artifact = Join-Path $appRoot "build/easyprivacy-$App-android$platformSuffix-$version-$mode.apk"
    Copy-Item -LiteralPath "build/app/outputs/flutter-apk/app-$mode.apk" -Destination $artifact -Force
    $checksum = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    "$checksum  $([IO.Path]::GetFileName($artifact))" | Set-Content -LiteralPath ($artifact+'.sha256') -Encoding ascii
    Write-Output $artifact
} finally { Pop-Location }
