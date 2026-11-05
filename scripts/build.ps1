# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputsPath,
    [Parameter(Mandatory)][string]$SdkRoot,
    [string]$OutputRoot = 'build'
)
. "$PSScriptRoot/common.ps1"
$root = Split-Path $PSScriptRoot -Parent
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'Native Windows x64 is required'
}
$InputsPath = (Resolve-Path -LiteralPath $InputsPath).Path
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
Assert-BundleInputs $inputs $root
$SdkRoot = (Resolve-Path -LiteralPath $SdkRoot).Path
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($SdkRoot.Contains(' ') -or $root.Contains(' ') -or $OutputRoot.Contains(' ')) { throw 'SDK and compilation paths must not contain spaces (installation paths may)' }
$bash = Join-Path $SdkRoot 'usr/bin/bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { throw 'Not a Git for Windows SDK' }
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
$env:BUNDLE_MINGW_PACKAGES_COMMIT = $inputs.toolchain.mingwPackagesCommit
$env:BUNDLE_BUILD_EXTRA_COMMIT = $inputs.toolchain.buildExtraCommit
$env:BUNDLE_BUSYBOX_COMMIT = $inputs.toolchain.busybox.commit
$env:BUNDLE_BUSYBOX_VERSION = $inputs.toolchain.busybox.version
$env:LC_ALL = 'C.UTF-8'
$env:BUNDLE_PWSH = Join-Path $PSHOME 'pwsh.exe'
$env:BUNDLE_PROJECT_ROOT = $root
$env:BUNDLE_OUTPUT_ROOT = $OutputRoot
$env:BUNDLE_INPUTS_PATH = $InputsPath
Invoke-BundleNative $bash @('--login', (Join-Path $PSScriptRoot 'build-git.sh'), $inputs.git.tag, $inputs.git.commit, $inputs.recipeCommit, $root, $OutputRoot)
& "$PSScriptRoot/build-lfs.ps1" -InputsPath $InputsPath -SdkRoot $SdkRoot -OutputRoot $OutputRoot
& "$PSScriptRoot/assemble-payload.ps1" -InputsPath $InputsPath -SdkRoot $SdkRoot -OutputRoot $OutputRoot
& "$PSScriptRoot/compile-installer.ps1" -InputsPath $InputsPath -OutputRoot $OutputRoot

# Keep the actual EXE available as a workflow artifact if source collection fails;
# formal publication still requires this complete corresponding-source archive.
$sourceOutput = Join-Path $OutputRoot 'work/redistribution-sources'
Invoke-BundleNative $bash @('--login', (Join-Path $PSScriptRoot 'collect-sources.sh'), (Join-Path $OutputRoot 'payload'), $sourceOutput)
$dist = Join-Path $root 'dist'
$sourcesZip = Join-Path $dist 'sources.zip'
if (Test-Path -LiteralPath $sourcesZip) { throw 'Source archive already exists' }
[IO.Compression.ZipFile]::CreateFromDirectory($sourceOutput, $sourcesZip, [IO.Compression.CompressionLevel]::Optimal, $false)
$checksums = @(Get-ChildItem -LiteralPath $dist -File | Sort-Object Name | ForEach-Object {
    if ($_.Name -eq 'SHA256SUMS') { throw 'Checksum manifest already exists' }
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
})
$checksums | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS') -Encoding utf8NoBOM
