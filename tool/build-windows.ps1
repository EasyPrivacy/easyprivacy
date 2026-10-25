param(
    [ValidateSet('core','vpn','files')][string]$App = 'core',
    [ValidatePattern('^[a-z0-9-]*$')][string]$PackageTag = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appRoot = Join-Path $repoRoot "apps/$App"
Push-Location $appRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Workspace resolution failed.' }
} finally { Pop-Location }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$staging = Join-Path $tempRoot ('ep-reorg-build-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    Push-Location $repoRoot
    try {
        $files = @(rg --files --hidden apps packages pubspec.yaml pubspec.lock analysis_options.yaml)
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate workspace sources.' }
        foreach ($relative in $files) {
            $destination = Join-Path $staging $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination
        }
    } finally { Pop-Location }
    New-Item -ItemType Directory -Path (Join-Path $staging '.dart_tool') -Force | Out-Null
    foreach ($metadata in @('package_config.json','package_graph.json')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot ".dart_tool/$metadata") -Destination (Join-Path $staging ".dart_tool/$metadata")
    }
    $configPath = Join-Path $staging '.dart_tool/package_config.json'
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    foreach ($package in $config.packages) {
        $uri = $null
        if ([Uri]::TryCreate($package.rootUri,[UriKind]::Absolute,[ref]$uri) -and $uri.IsFile) {
            $local = $uri.LocalPath
            if ($local.StartsWith($repoRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
                $package.rootUri = [Uri]::new((Join-Path $staging $local.Substring($repoRoot.Length+1))+[IO.Path]::DirectorySeparatorChar).AbsoluteUri
            }
        }
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding utf8
    $stagedApp = Join-Path $staging "apps/$App"
    foreach ($generated in @('.flutter-plugins-dependencies','windows/flutter/generated_plugins.cmake','windows/flutter/generated_plugin_registrant.cc','windows/flutter/generated_plugin_registrant.h')) {
        $destination = Join-Path $stagedApp $generated
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $appRoot $generated) -Destination $destination
    }
    if ($App -in @('core','vpn')) {
        $nativeSource = Join-Path $appRoot 'native/windows'
        if (-not (Test-Path -LiteralPath (Join-Path $nativeSource 'easyprivacy-vpn.exe'))) { throw 'Run tool/build-vpn-windows.sh first.' }
        New-Item -ItemType Directory -Force -Path (Join-Path $stagedApp 'native/windows') | Out-Null
        Copy-Item -Path (Join-Path $nativeSource '*') -Destination (Join-Path $stagedApp 'native/windows') -Force
    }
    if ($App -eq 'core' -and -not (Test-Path -LiteralPath (Join-Path $stagedApp 'native/windows/easyprivacy_pairing.dll'))) {
        throw 'Run tool/build-pairing.ps1 before packaging Core.'
    }
    if ($App -eq 'files') {
        $syncEngine = Join-Path $appRoot 'native/windows/easyprivacy-sync.exe'
        if (-not (Test-Path -LiteralPath $syncEngine)) { throw 'Run tool/build-sync-engine.ps1 before packaging Files.' }
        New-Item -ItemType Directory -Force -Path (Join-Path $stagedApp 'native/windows') | Out-Null
        Copy-Item -LiteralPath $syncEngine -Destination (Join-Path $stagedApp 'native/windows') -Force
    }
    $plugins = Get-Content -Raw -LiteralPath (Join-Path $stagedApp '.flutter-plugins-dependencies') | ConvertFrom-Json
    $links = Join-Path $stagedApp 'windows/flutter/ephemeral/.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $links | Out-Null
    foreach ($plugin in $plugins.plugins.windows) {
        New-Item -ItemType Junction -Path (Join-Path $links $plugin.name) -Target ([IO.Path]::GetFullPath($plugin.path)) | Out-Null
    }
    Push-Location $stagedApp
    try {
        flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    } finally { Pop-Location }
    $suffix = if ($PackageTag) { '-'+$PackageTag } else { '' }
    $output = Join-Path $appRoot ('build/windows-package'+$suffix)
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    Copy-Item -Path (Join-Path $stagedApp 'build/windows/x64/runner/Release/*') -Destination $output -Recurse -Force
    $version = (Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'VERSION')).Trim()
    $archive = Join-Path $appRoot "build/easyprivacy-$App-windows-$version-x64$suffix.zip"
    # Flutter bundles have identically named data/app.so and asset files.
    # Include a distinct top-level folder so extracting several app ZIPs into
    # one location cannot overwrite another application's runtime payload.
    $folderName = switch ($App) {
        'core' { 'EasyPrivacy Core' }
        'vpn' { 'EasyPrivacy VPN' }
        'files' { 'EasyPrivacy Files' }
    }
    $packageFolder = Join-Path (Join-Path $staging 'packages') $folderName
    New-Item -ItemType Directory -Force -Path $packageFolder | Out-Null
    Copy-Item -Path (Join-Path $output '*') -Destination $packageFolder -Recurse
    Compress-Archive -LiteralPath $packageFolder -DestinationPath $archive -Force
    $checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$checksum  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath ($archive+'.sha256') -Encoding ascii
    Write-Output $archive
} finally {
    $resolved = [IO.Path]::GetFullPath($staging)
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('ep-reorg-build-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { throw 'Refused to remove an unexpected staging directory.' }
}
