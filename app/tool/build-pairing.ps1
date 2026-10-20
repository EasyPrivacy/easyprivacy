$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectRoot = Split-Path -Parent $appRoot
$manifest = Join-Path $projectRoot 'native/pairing/Cargo.toml'
$cargo = (Get-Command cargo -ErrorAction SilentlyContinue).Source
if (-not $cargo) {
    $env:CARGO_HOME = Join-Path $projectRoot '.tools/cargo-windows'
    $env:RUSTUP_HOME = Join-Path $projectRoot '.tools/rustup-windows'
    $cargo = Join-Path $env:CARGO_HOME 'bin/cargo.exe'
}
if (-not (Test-Path -LiteralPath $cargo)) { throw 'Install Rust with the Windows MSVC toolchain.' }
& $cargo build --locked --manifest-path $manifest --target x86_64-pc-windows-msvc --release
if ($LASTEXITCODE -ne 0) { throw 'Native Windows PAKE build failed.' }
$windows = Join-Path $appRoot 'native/windows'
New-Item -ItemType Directory -Force -Path $windows | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'native/pairing/target/x86_64-pc-windows-msvc/release/easyprivacy_pairing.dll') -Destination $windows -Force
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
$ndk = Get-ChildItem -LiteralPath (Join-Path $sdk 'ndk') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $ndk) { throw 'Install the Android NDK.' }
$toolchain = Join-Path $ndk.FullName 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$targets = @(
    @{ Rust='aarch64-linux-android'; Abi='arm64-v8a'; Linker='aarch64-linux-android24-clang.cmd' },
    @{ Rust='armv7-linux-androideabi'; Abi='armeabi-v7a'; Linker='armv7a-linux-androideabi24-clang.cmd' },
    @{ Rust='x86_64-linux-android'; Abi='x86_64'; Linker='x86_64-linux-android24-clang.cmd' }
)
foreach ($target in $targets) {
    $linkerSetting = 'CARGO_TARGET_' + $target.Rust.ToUpperInvariant().Replace('-', '_') + '_LINKER'
    [Environment]::SetEnvironmentVariable($linkerSetting, (Join-Path $toolchain $target.Linker), 'Process')
    & $cargo build --locked --manifest-path $manifest --target $target.Rust --release
    if ($LASTEXITCODE -ne 0) { throw ('Native Android PAKE build failed for ' + $target.Rust) }
    $destination = Join-Path $appRoot ('android/app/src/main/jniLibs/' + $target.Abi)
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot ('native/pairing/target/' + $target.Rust + '/release/libeasyprivacy_pairing.so')) -Destination $destination -Force
}
Write-Output 'Built native PAKE for Windows and all Android APK architectures.'
