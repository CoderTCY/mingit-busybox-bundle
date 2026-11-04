# SPDX-License-Identifier: GPL-2.0-only
. "$PSScriptRoot/common.ps1"

function Assert-BundleRepository {
    param([string]$Repository)
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository identity' }
}

function ConvertTo-BundleCanonicalJson {
    param($Value)
    function Convert-Node($Node) {
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($Node.Keys | Sort-Object -CaseSensitive)) { $result[$key] = Convert-Node $Node[$key] }
            return $result
        }
        if ($Node -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($key in @($Node.PSObject.Properties.Name | Sort-Object -CaseSensitive)) { $result[$key] = Convert-Node $Node.$key }
            return $result
        }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            $items = @($Node | ForEach-Object { Convert-Node $_ })
            return ,$items
        }
        return $Node
    }
    return (Convert-Node $Value | ConvertTo-Json -Depth 100 -Compress)
}

function Assert-BundleSameInputs {
    param($Expected, $Actual)
    if ((ConvertTo-BundleCanonicalJson $Expected) -cne (ConvertTo-BundleCanonicalJson $Actual)) {
        throw 'Release identity conflict: original fixed inputs do not match this run'
    }
}

function Get-BundleRelease {
    param([string]$Repository, [string]$Tag)
    Assert-BundleRepository $Repository
    $matches = @()
    for ($page = 1; ; $page++) {
        # Listing (rather than swallowing a tags/404 error) includes drafts and
        # distinguishes an absent release from authentication/network failures.
        $batch = @(Get-BundleApi "repos/$Repository/releases?per_page=100&page=$page")
        $matches += @($batch | Where-Object tag_name -CEQ $Tag)
        if ($batch.Count -lt 100) { break }
    }
    if ($matches.Count -gt 1) { throw "Ambiguous release identity: $Tag" }
    if ($matches.Count -eq 0) { return $null }
    $release = $matches[0]
    $assets = @()
    for ($page = 1; ; $page++) {
        $batch = @(Get-BundleApi "repos/$Repository/releases/$($release.id)/assets?per_page=100&page=$page")
        $assets += $batch
        if ($batch.Count -lt 100) { break }
    }
    $release.assets = $assets
    return $release
}

function Receive-BundleApiFile {
    param([string]$ApiPath, [string]$Destination, [string]$Accept = 'application/vnd.github+json')
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if (-not $token) { throw 'Authenticated GitHub download requires a token' }
    $headers = @{ Authorization = "Bearer $token"; Accept = $Accept; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'MinGit-BusyBox-Bundle' }
    # PowerShell strips Authorization on redirects to the signed asset host.
    Invoke-WebRequest -Uri "https://api.github.com/$ApiPath" -Headers $headers -OutFile $Destination
}

function Receive-BundleReleaseAsset {
    param([string]$Repository, $Release, [string]$Name, [string]$Destination)
    $assets = @($Release.assets | Where-Object name -CEQ $Name)
    if ($assets.Count -ne 1 -or $assets[0].state -cne 'uploaded') { throw "Release lacks unique uploaded $Name" }
    Receive-BundleApiFile "repos/$Repository/releases/assets/$($assets[0].id)" $Destination -Accept 'application/octet-stream'
    if ((Get-Item -LiteralPath $Destination).Length -ne $assets[0].size) { throw "Downloaded asset length mismatch: $Name" }
    if ($assets[0].PSObject.Properties.Name -contains 'digest' -and $assets[0].digest) {
        $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($assets[0].digest -cne "sha256:$hash") { throw "Downloaded asset digest mismatch: $Name" }
    }
}

function Assert-BundleReleaseInputs {
    param([string]$Repository, $Release, $Inputs)
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('bundle-identity-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    try {
        foreach ($name in @('inputs.json', 'build-manifest.json')) {
            Receive-BundleReleaseAsset $Repository $Release $name (Join-Path $temporary $name)
        }
        $original = Get-Content -LiteralPath (Join-Path $temporary 'inputs.json') -Raw | ConvertFrom-Json
        $manifest = Get-Content -LiteralPath (Join-Path $temporary 'build-manifest.json') -Raw | ConvertFrom-Json
        Assert-BundleSameInputs $Inputs $original
        Assert-BundleSameInputs $Inputs $manifest.inputs
        if ($Release.prerelease) { throw 'Stable bundle identity is occupied by a prerelease' }
        if ($Release.draft -and $Release.target_commitish -cne $Inputs.recipeCommit) { throw 'Draft target differs from the fixed recipe commit' }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}

function Get-BundleReleaseFileNames {
    param($Inputs)
    if ($Inputs.releaseTag -cnotmatch '^gfw-\d+\.\d+\.\d+\.windows\.\d+-lfs-\d+\.\d+\.\d+-r[0-9a-f]{12}$') { throw 'Unsafe release filename identity' }
    return @("MinGit-BusyBox-Bundle-$($Inputs.releaseTag)-x64.exe", 'build-manifest.json', 'inputs.json', 'sources.zip', 'SHA256SUMS')
}
