$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $repoRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    $dartSources = @(rg --files apps packages -g '*.dart')
    dart format --output=none --set-exit-if-changed $dartSources
    if ($LASTEXITCODE -ne 0) { throw 'Dart formatting failed.' }
    flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Analysis failed.' }
    node tool/check-boundaries.cjs
    if ($LASTEXITCODE -ne 0) { throw 'Application dependency boundary failed.' }
    foreach ($member in @('apps/core','apps/vpn','apps/files','packages/easyprivacy_core_sdk')) {
        Push-Location $member
        try {
            flutter test --no-pub
            if ($LASTEXITCODE -ne 0) { throw "Tests failed in $member." }
        } finally { Pop-Location }
    }
} finally { Pop-Location }
