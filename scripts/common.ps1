# SPDX-License-Identifier: GPL-2.0-only
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-BundleNative {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @())
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File exited with code $LASTEXITCODE" }
}

function Get-BundleApi {
    param([Parameter(Mandatory)][string]$Path)
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'MinGit-BusyBox-Bundle'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($token) { $headers.Authorization = "Bearer $token" }
    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/$Path" -Headers $headers
        return $response
    }
    catch { throw "GitHub API $Path failed: $($_.Exception.Message)" }
}

function Get-BundleAsset {
    param([Parameter(Mandatory)]$Release, [Parameter(Mandatory)][string]$Name)
    $assets = @($Release.assets | Where-Object name -CEQ $Name)
    if ($assets.Count -ne 1) { throw "Expected exactly one $Name in release $($Release.tag_name); found $($assets.Count)" }
    $asset = $assets[0]
    if ($asset.state -ne 'uploaded') { throw "Asset $Name is not uploaded" }
    $hash = if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLowerInvariant() } else { $null }
    if (-not $hash) {
        $sums = @($Release.assets | Where-Object name -CEQ 'sha256sums.asc')
        if ($sums.Count -ne 1) { throw "No official SHA-256 metadata for $Name" }
        $text = (Invoke-WebRequest -Uri $sums[0].browser_download_url).Content
        $entries = @([regex]::Matches([string]$text, '(?m)^([0-9a-fA-F]{64})[ \t]+\*?' + [regex]::Escape($Name) + '\r?$'))
        if ($entries.Count -ne 1) { throw "No unique official SHA-256 entry for $Name" }
        $hash = $entries[0].Groups[1].Value.ToLowerInvariant()
    }
    [ordered]@{ assetId = $asset.id; name = $Name; url = $asset.browser_download_url; sha256 = $hash }
}

function Receive-BundleFile {
    param([Parameter(Mandatory)]$Asset, [Parameter(Mandatory)][string]$Destination)
    if ($Asset.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Missing SHA-256' }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination))) | Out-Null
    if (-not (Test-Path -LiteralPath $Destination)) {
        Invoke-WebRequest -Uri $Asset.url -OutFile "$Destination.partial"
        Move-Item -LiteralPath "$Destination.partial" -Destination $Destination
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $Asset.sha256) { throw "SHA-256 mismatch for $Destination; expected $($Asset.sha256), got $actual" }
    return [IO.Path]::GetFullPath($Destination)
}

function Assert-BundleInputs {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$ProjectRoot)
    if ($Inputs.architecture -cne 'x64' -or $Inputs.recipeCommit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid input identity' }
    if ($Inputs.git.commit -notmatch '^[0-9a-f]{40}$') { throw 'Git source is not a pinned commit' }
    $recipe = (& git -C $ProjectRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $recipe -cne $Inputs.recipeCommit) { throw 'Recipe checkout differs from input snapshot' }
    $expected = 'gfw-{0}-lfs-{1}-r{2}' -f $Inputs.git.tag.Substring(1), $Inputs.lfs.tag.Substring(1), $recipe.Substring(0,12)
    if ($Inputs.releaseTag -cne $expected) { throw 'Release identity differs from input snapshot' }
    $lock = Get-Content -LiteralPath (Join-Path $ProjectRoot 'build/toolchain.lock.json') -Raw | ConvertFrom-Json
    if (($lock | ConvertTo-Json -Depth 20 -Compress) -cne ($Inputs.toolchain | ConvertTo-Json -Depth 20 -Compress)) { throw 'Toolchain lock differs from snapshot' }
    if ($Inputs.toolchain.busybox.commit -notmatch '^[0-9a-f]{40}$') { throw 'BusyBox source is not a pinned commit' }
    if ($Inputs.lfs.commit -notmatch '^[0-9a-f]{40}$' -or $Inputs.lfs.source.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'LFS source is not pinned' }
    if ($Inputs.lfs.vendor -cne ("MinGitBusyBoxBundle.r" + $recipe.Substring(0,12))) { throw 'Target LFS must identify this custom build' }
    $expectedPatches = @('patches/0001-core-shell.patch', 'patches/0002-package-inputs.patch', 'patches/0003-busybox-unicode.patch', 'patches/0004-busybox-package-inputs.patch', 'patches/0005-lfs-core-shell.patch')
    if (($Inputs.patches.path -join "`n") -cne ($expectedPatches -join "`n")) { throw 'All five reviewed Git, BusyBox and LFS patches are required' }
    foreach ($patch in $Inputs.patches) {
        if ((Get-FileHash -LiteralPath (Join-Path $ProjectRoot $patch.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $patch.sha256) { throw "Patch changed: $($patch.path)" }
    }
}
