# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param([string]$GitTag, [string]$LfsTag, [string]$OutputPath = 'build/inputs.json')
. "$PSScriptRoot/common.ps1"
$root = Split-Path $PSScriptRoot -Parent

function Get-StableRelease {
    param([string]$Repository, [string]$Tag, [string]$Pattern)
    if ($Tag -and $Tag -cnotmatch $Pattern) { throw "Invalid stable tag: $Tag" }
    $suffix = if ($Tag) { 'tags/' + [Uri]::EscapeDataString($Tag) } else { 'latest' }
    $release = Get-BundleApi "repos/$Repository/releases/$suffix"
    if ($release.draft -or $release.prerelease -or $release.tag_name -cnotmatch $Pattern) { throw "Not a stable release: $Repository $($release.tag_name)" }
    if ($Tag -and $release.tag_name -cne $Tag) { throw 'Release tag mismatch' }
    foreach ($part in @([regex]::Matches($release.tag_name, '\d+') | ForEach-Object Value)) {
        $number = 0
        if (-not [uint16]::TryParse($part, [ref]$number)) { throw "Version cannot fit PE fields: $($release.tag_name)" }
    }
    return $release
}

function Resolve-Commit {
    param([string]$Repository, [string]$Tag)
    $reference = Get-BundleApi "repos/$Repository/git/ref/tags/$([Uri]::EscapeDataString($Tag))"
    $object = $reference.object
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($object.type -ceq 'tag') {
        if (-not $seen.Add($object.sha)) { throw 'Cyclic annotated tag' }
        $object = (Get-BundleApi "repos/$Repository/git/tags/$($object.sha)").object
    }
    if ($object.type -cne 'commit' -or $object.sha -cnotmatch '^[0-9a-f]{40}$') { throw "Tag $Tag does not resolve to a commit" }
    return $object.sha
}

function Resolve-Lfs {
    param($Release, [Parameter(Mandatory)][string]$Vendor, [switch]$ReleaseBinary)
    $tag = $Release.tag_name
    $result = [ordered]@{
        tag = $tag
        version = $tag.Substring(1)
        commit = Resolve-Commit 'git-lfs/git-lfs' $tag
        releaseId = $Release.id
        vendor = $Vendor
        source = Get-BundleAsset $Release "git-lfs-vendor-$tag.tar.gz"
    }
    if ($ReleaseBinary) {
        $asset = Get-BundleAsset $Release "git-lfs-windows-amd64-$tag.zip"
        foreach ($key in $asset.Keys) { $result[$key] = $asset[$key] }
    }
    return $result
}

if (Test-Path -LiteralPath $OutputPath) { throw "Input snapshot already exists: $OutputPath. Reuse it for this run; choose a new output path for new resolution." }
$gitPattern = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.windows\.(0|[1-9]\d*)$'
$lfsPattern = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
$gitRelease = Get-StableRelease 'git-for-windows/git' $GitTag $gitPattern
$lfsRelease = Get-StableRelease 'git-lfs/git-lfs' $LfsTag $lfsPattern
$recipe = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $recipe -cnotmatch '^[0-9a-f]{40}$') { throw 'Commit the recipe before resolving inputs' }
$gitVersion = $gitRelease.tag_name.Substring(1).Replace('.windows.', '.')
# Upstream omits the Windows revision only for .windows.1 asset filenames.
# Keep the four-part package/PE version separate from that naming convention.
$assetVersion = $gitVersion -replace '\.1$', ''
$baseline = Get-BundleAsset $gitRelease "MinGit-$assetVersion-busybox-64-bit.zip"
$lfs = Resolve-Lfs $lfsRelease -Vendor ("MinGitBusyBoxBundle.r" + $recipe.Substring(0,12))

# Lock the highest older stable release for the real LFS-only upgrade fixture.
$older = @()
$page = 1
while ($true) {
    $releases = @(Get-BundleApi "repos/git-lfs/git-lfs/releases?per_page=100&page=$page")
    foreach ($release in $releases) {
        if (-not $release.draft -and -not $release.prerelease -and $release.tag_name -cmatch $lfsPattern) {
            $version = [version]$release.tag_name.Substring(1)
            if ($version -lt [version]$lfs.version) { $older += $release }
        }
    }
    if ($releases.Count -lt 100) { break }
    $page++
}
if ($older.Count -eq 0) { throw 'No older stable LFS release available for the upgrade gate' }
$previous = $older | Sort-Object { [version]$_.tag_name.Substring(1) } -Descending | Select-Object -First 1
$oldLfs = Resolve-Lfs $previous -Vendor 'GitHub' -ReleaseBinary
$patches = @(Get-ChildItem -LiteralPath (Join-Path $root 'patches') -Filter '*.patch' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    [ordered]@{ path = "patches/$($_.Name)"; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$expectedPatches = @('patches/0001-core-shell.patch', 'patches/0002-package-inputs.patch', 'patches/0003-busybox-unicode.patch', 'patches/0004-busybox-package-inputs.patch', 'patches/0005-lfs-core-shell.patch')
if (($patches.path -join "`n") -cne ($expectedPatches -join "`n")) {
    throw 'All five reviewed Git, BusyBox and LFS patches are required'
}
$inputs = [ordered]@{
    schemaVersion = 1
    architecture = 'x64'
    recipeCommit = $recipe
    git = [ordered]@{ tag = $gitRelease.tag_name; commit = Resolve-Commit 'git-for-windows/git' $gitRelease.tag_name; releaseId = $gitRelease.id; packageVersion = $gitVersion }
    lfs = $lfs
    baseline = $baseline
    upgradeFixture = [ordered]@{ lfs = $oldLfs }
    toolchain = Get-Content -LiteralPath (Join-Path $root 'build/toolchain.lock.json') -Raw | ConvertFrom-Json
    patches = $patches
    releaseTag = 'gfw-{0}-lfs-{1}-r{2}' -f $gitRelease.tag_name.Substring(1), $lfs.version, $recipe.Substring(0,12)
    appVersion = '{0}+lfs.{1}.r{2}' -f $gitVersion, $lfs.version, $recipe.Substring(0,12)
}
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))) | Out-Null
$inputs | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Resolved $($inputs.releaseTag) to $OutputPath"
