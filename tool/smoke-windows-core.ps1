param([string]$Bundle = (Join-Path $PSScriptRoot '../apps/core/build/windows-package'))
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this smoke test in PowerShell on Windows.' }
$bundlePath = [IO.Path]::GetFullPath($Bundle)
$executable = Join-Path $bundlePath 'easyprivacy.exe'
foreach ($name in @('easyprivacy.exe','easyprivacy_pairing.dll','easyprivacy-core-runtime.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundlePath $name))) { throw "Missing bundle artifact: $name" }
}
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempRoot ('easyprivacy-core-smoke-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$broker = $null
$duplicate = $null
$originalAppData = $env:APPDATA
try {
    # privateStatus never reads enrollment or starts a remote connection. Only
    # this process's registry location changes; the user's vault is untouched.
    $env:APPDATA = $testRoot
    $broker = Start-Process -FilePath $executable -ArgumentList '--core-broker' -WorkingDirectory $bundlePath -WindowStyle Hidden -PassThru
    $env:APPDATA = $originalAppData
    $registryPath = Join-Path $testRoot 'EasyPrivacy/Core/broker.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $registryPath)) {
        if ($broker.HasExited) { throw 'Broker exited before publishing its registry. Close an existing Core broker before running this isolated test.' }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Packaged Core broker did not become ready.' }
        Start-Sleep -Milliseconds 200
    }
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    $endpoint = [Uri]$registry.endpoint
    if ($endpoint.Scheme -ne 'http' -or $endpoint.Host -ne '127.0.0.1') { throw 'Unexpected broker endpoint.' }
    $requestUri = [Uri]::new($endpoint, '/v1/rpc')
    $request = @{ protocol=1; capability='core'; method='privateStatus'; arguments=@{} } | ConvertTo-Json -Compress
    $headers = @{ Authorization=('Bearer '+$registry.token) }
    $status = Invoke-RestMethod -Uri $requestUri -Method Post -ContentType 'application/json' -Headers $headers -Body $request -TimeoutSec 5
    if ($status.active -or $status.starting) { throw 'Isolated broker unexpectedly started a private connection.' }
    $denied = $false
    try { Invoke-RestMethod -Uri $requestUri -Method Post -ContentType 'application/json' -Body $request -TimeoutSec 5 | Out-Null }
    catch { $denied = [int]$_.Exception.Response.StatusCode -eq 403 }
    if (-not $denied) { throw 'Broker did not reject an unauthenticated caller.' }
    $env:APPDATA = $testRoot
    $duplicate = Start-Process -FilePath $executable -ArgumentList '--core-broker' -WorkingDirectory $bundlePath -WindowStyle Hidden -PassThru
    $env:APPDATA = $originalAppData
    if (-not $duplicate.WaitForExit(5000) -or $duplicate.ExitCode -ne 0) { throw 'Duplicate broker did not exit cleanly.' }
    $status = Invoke-RestMethod -Uri $requestUri -Method Post -ContentType 'application/json' -Headers $headers -Body $request -TimeoutSec 5
    if ($broker.HasExited -or $status.active) { throw 'Duplicate launch disrupted the original broker.' }
    Write-Output 'PASS: packaged Core broker starts, authenticates local RPC, rejects missing credentials, and survives duplicate launch.'
} finally {
    $env:APPDATA = $originalAppData
    foreach ($process in @($duplicate, $broker)) {
        if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id; $process.WaitForExit() }
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('easyprivacy-core-smoke-')) {
        throw 'Refused to remove an unexpected smoke-test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
