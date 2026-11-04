# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputsPath,
    [Parameter(Mandatory)][string]$SdkRoot,
    [string]$OutputRoot = 'build'
)
. "$PSScriptRoot/common.ps1"
$root = Split-Path $PSScriptRoot -Parent
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
$env:LC_ALL = 'C.UTF-8'
Invoke-BundleNative $bash @('--login', (Join-Path $PSScriptRoot 'build-git.sh'), $inputs.git.tag, $inputs.git.commit, $inputs.recipeCommit, $root, $OutputRoot)
