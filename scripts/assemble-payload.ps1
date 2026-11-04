# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputsPath, [Parameter(Mandatory)][string]$SdkRoot, [Parameter(Mandatory)][string]$OutputRoot)
. "$PSScriptRoot/payload.ps1"
$root = Split-Path $PSScriptRoot -Parent
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
Assert-BundleInputs $inputs $root
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$SdkRoot = [IO.Path]::GetFullPath($SdkRoot)
$work = Join-Path $OutputRoot 'work'
$payload = Join-Path $OutputRoot 'payload'
if (Test-Path -LiteralPath $payload) { throw "Payload destination already exists: $payload" }
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
$env:BUNDLE_GIT_TAG = $inputs.git.tag
$env:BUNDLE_BUILD_EXTRA_COMMIT = $inputs.toolchain.buildExtraCommit
Invoke-BundleNative (Join-Path $SdkRoot 'usr/bin/bash.exe') @('--login', (Join-Path $PSScriptRoot 'export-payload.sh'), $root, $OutputRoot, $inputs.git.packageVersion, $inputs.recipeCommit)
$exports = @(Get-ChildItem -LiteralPath (Join-Path $work 'export') -Filter '*.zip' -File)
if ($exports.Count -ne 1) { throw 'Official MinGit exporter must produce exactly one ZIP' }
Expand-Archive -LiteralPath $exports[0].FullName -DestinationPath $payload
foreach ($required in @('cmd/git.exe','ucrt64/bin/git.exe','ucrt64/bin/ash.exe','ucrt64/bin/busybox.exe','ucrt64/bin/libintl-8.dll','ucrt64/bin/libiconv-2.dll','etc/libexec-moved.txt','etc/package-versions.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $required))) { throw "Exporter omitted required file: $required" }
}
$docs = Join-Path $SdkRoot 'ucrt64/share/doc/git-doc'
$docTarget = Join-Path $payload 'ucrt64/share/doc/git-doc'
[IO.Directory]::CreateDirectory($docTarget) | Out-Null
Get-ChildItem -LiteralPath $docs -Force | Copy-Item -Destination $docTarget -Recurse -Force
$sourceLocales = @(Get-Content -LiteralPath (Join-Path $work 'source-locales.txt') | Where-Object { $_ })
foreach ($locale in $sourceLocales) {
    if ($locale -notmatch '^[a-zA-Z_@0-9.-]+$') { throw 'Invalid source locale inventory' }
    $relative = "ucrt64/share/locale/$locale/LC_MESSAGES/git.mo"
    $source = Join-Path $SdkRoot $relative
    $destination = Join-Path $payload $relative
    if (-not (Test-Path -LiteralPath $source)) { throw "This Git package omitted source catalog: $locale" }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
}
Copy-Item -LiteralPath (Join-Path $work 'mingit-open.exe') -Destination (Join-Path $payload 'ucrt64/bin/mingit-open.exe')
Set-BundleLfs -Lfs $inputs.lfs -Payload $payload -Work $work

# Exporter's system configuration may include unrelated full Git installations.
# Replace it with independently versioned defaults; never import host/SDK config.
$upstreamDefaults = Get-Content -LiteralPath (Join-Path $work 'build-extra/git-extra/gitconfig') -Raw
$integration = @'
[core]
    shell = %(prefix)/bin/ash.exe
[help]
    format = html
    browser = mingit-bundle
[browser "mingit-bundle"]
    cmd = mingit-open.exe
[filter "lfs"]
    clean = git-lfs clean -- %f
    smudge = git-lfs smudge -- %f
    process = git-lfs filter-process
    required = true
'@
$upstreamDefaults.TrimEnd() + "`n" + $integration + "`n" | Set-Content -LiteralPath (Join-Path $payload 'etc/gitconfig.bundle') -Encoding utf8NoBOM
"[include]`n    path = gitconfig.bundle`n" | Set-Content -LiteralPath (Join-Path $payload 'etc/gitconfig') -Encoding utf8NoBOM
$alternateConfig = Join-Path $payload 'ucrt64/etc/gitconfig'
if (Test-Path -LiteralPath $alternateConfig) { Remove-Item -LiteralPath $alternateConfig }
$licenseDir = Join-Path $payload 'ucrt64/share/licenses/mingit-busybox-bundle'
[IO.Directory]::CreateDirectory($licenseDir) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'COPYING') -Destination $licenseDir
$manifest = [ordered]@{
    schemaVersion = 1
    inputs = $inputs
    sourceLocales = $sourceLocales
    sdkPackages = @(Get-Content -LiteralPath (Join-Path $work 'sdk-packages.txt'))
    compiler = @(Get-Content -LiteralPath (Join-Path $work 'compiler.txt'))
    components = [ordered]@{
        git = [ordered]@{ commit = $inputs.git.commit; packages = @(Get-Content -LiteralPath (Join-Path $work 'built-packages.txt') | ForEach-Object { [IO.Path]::GetFileName($_) }) }
        lfs = $inputs.lfs
        exporter = [ordered]@{ commit = $inputs.toolchain.buildExtraCommit; sha256 = (Get-FileHash -LiteralPath $exports[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        opener = [ordered]@{ source = 'native/mingit-open.c'; recipeCommit = $inputs.recipeCommit }
    }
    files = @()
}
Write-BundlePayloadManifest -Payload $payload -Manifest $manifest
Write-Host "Assembled single offline payload at $payload"
