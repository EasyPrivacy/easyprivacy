$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseVersion = (Get-Content -Raw -LiteralPath (Join-Path $sourceRoot '../VERSION')).Trim()
if ($releaseVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid project VERSION.' }
$tempRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'))
$staging = Join-Path $tempRoot ('ep-mvp-build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    # Stage source at a short path to avoid MSBuild's path-length limits in
    # nested worktrees. rg respects the project's generated-file exclusions.
    Push-Location $sourceRoot
    try {
        $files = @(rg --files --hidden)
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate app sources.' }
        foreach ($relative in $files) {
            $destination = Join-Path $staging $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination
        }
    } finally { Pop-Location }
    New-Item -ItemType Directory -Force -Path (Join-Path $staging '.dart_tool') | Out-Null
    foreach ($generated in @('.dart_tool/package_config.json', '.dart_tool/package_graph.json', '.flutter-plugins-dependencies',
        'windows/flutter/generated_plugins.cmake', 'windows/flutter/generated_plugin_registrant.cc', 'windows/flutter/generated_plugin_registrant.h',
        'linux/flutter/generated_plugins.cmake', 'linux/flutter/generated_plugin_registrant.cc', 'linux/flutter/generated_plugin_registrant.h')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $generated))) {
            throw 'Run flutter pub get in the source app before building.'
        }
        Copy-Item -LiteralPath (Join-Path $sourceRoot $generated) -Destination (Join-Path $staging $generated)
    }
    $native = Join-Path $sourceRoot 'native/windows/easyprivacy_pairing.dll'
    if (-not (Test-Path -LiteralPath $native)) { throw 'Run tool/build-pairing.ps1 first.' }
    New-Item -ItemType Directory -Force -Path (Join-Path $staging 'native/windows') | Out-Null
    Copy-Item -LiteralPath $native -Destination (Join-Path $staging 'native/windows/easyprivacy_pairing.dll')
    $vpnHelper = Join-Path $sourceRoot 'native/windows/easyprivacy-vpn.exe'
    if (-not (Test-Path -LiteralPath $vpnHelper)) { throw 'Build the native Windows VPN helper first.' }
    Copy-Item -LiteralPath $vpnHelper -Destination (Join-Path $staging 'native/windows/easyprivacy-vpn.exe')
    Push-Location $staging
    try {
        $metadata = Get-Content -Raw -LiteralPath '.flutter-plugins-dependencies' | ConvertFrom-Json
        foreach ($platform in @('windows', 'linux')) {
            $links = Join-Path $staging ($platform + '/flutter/ephemeral/.plugin_symlinks')
            New-Item -ItemType Directory -Force -Path $links | Out-Null
            foreach ($plugin in $metadata.plugins.$platform) {
                $target = [IO.Path]::GetFullPath($plugin.path)
                if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw 'Plugin cache directory is missing.' }
                New-Item -ItemType Junction -Path (Join-Path $links $plugin.name) -Target $target | Out-Null
            }
        }
        # Junctions provide the plugin directory links without requiring a
        # system-wide Developer Mode setting or administrator terminal.
        flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
        $release = Join-Path $staging 'build/windows/x64/runner/Release'
        $output = Join-Path $sourceRoot 'build/windows-package'
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        Copy-Item -Path (Join-Path $release '*') -Destination $output -Recurse -Force
        $archive = Join-Path $sourceRoot ("build/easyprivacy-windows-$releaseVersion-x64.zip")
        Compress-Archive -Path (Join-Path $output '*') -DestinationPath $archive -Force
        $checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        "$checksum  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ascii
        # Keep existing local download links pointed at the latest build.
        $latest = Join-Path $sourceRoot 'build/easyprivacy-windows-x64.zip'
        Copy-Item -LiteralPath $archive -Destination $latest -Force
        "$checksum  $([IO.Path]::GetFileName($latest))" | Set-Content -LiteralPath ($latest + '.sha256') -Encoding ascii
        Write-Output "Windows application: $output"
        Write-Output "Desktop archive: $archive"
    } finally { Pop-Location }
} finally {
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    if ($resolvedStaging.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedStaging).StartsWith('ep-mvp-build-')) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
    } else {
        throw 'Refused to remove an unexpected staging directory.'
    }
}
