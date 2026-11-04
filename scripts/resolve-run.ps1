# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$GitTag,
    [string]$LfsTag,
    [string]$OutputPath = 'build/inputs.json'
)
. "$PSScriptRoot/release-state.ps1"
Assert-BundleRepository $Repository
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_RUN_ID -notmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^\d+$' -or -not $env:GITHUB_OUTPUT) { throw 'Run resolution requires GitHub Actions run identity' }
if ($Repository -cne $env:GITHUB_REPOSITORY) { throw 'Repository differs from workflow identity' }
$root = Split-Path $PSScriptRoot -Parent
$name = "inputs-$($env:GITHUB_RUN_ID)"
$found = @()
for ($page = 1; ; $page++) {
    $response = Get-BundleApi "repos/$Repository/actions/runs/$($env:GITHUB_RUN_ID)/artifacts?per_page=100&page=$page"
    $found += @($response.artifacts | Where-Object name -CEQ $name)
    if (@($response.artifacts).Count -lt 100) { break }
}
if ($found.Count -gt 1) { throw 'Multiple original input snapshots found; refusing an ambiguous rerun' }
if (Test-Path -LiteralPath $OutputPath) { throw "Unexpected existing inputs file: $OutputPath" }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))) | Out-Null
if ($found.Count -eq 1) {
    if ($found[0].expired) { throw 'Original input snapshot expired; this run cannot resolve replacement inputs' }
    $temporary = Join-Path $env:RUNNER_TEMP ('input-snapshot-' + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        Receive-BundleApiFile "repos/$Repository/actions/artifacts/$($found[0].id)/zip" $temporary
        $archive = [IO.Compression.ZipFile]::OpenRead($temporary)
        try {
            if ($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -cne 'inputs.json' -or $archive.Entries[0].Length -gt 1048576) { throw 'Invalid input snapshot archive layout' }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.Entries[0], [IO.Path]::GetFullPath($OutputPath), $false)
        } finally { $archive.Dispose() }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    'new_snapshot=false' | Add-Content -LiteralPath $env:GITHUB_OUTPUT
} else {
    if ([long]$env:GITHUB_RUN_ATTEMPT -ne 1) { throw 'Original input snapshot is missing. Start a new run; reruns must never resolve latest again.' }
    & "$PSScriptRoot/resolve-inputs.ps1" -GitTag $GitTag -LfsTag $LfsTag -OutputPath $OutputPath
    # Persist even if the subsequent release-state API call fails.
    'new_snapshot=true' | Add-Content -LiteralPath $env:GITHUB_OUTPUT
}
$inputs = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
Assert-BundleInputs $inputs $root
$null = Get-BundleReleaseFileNames $inputs
if ($inputs.recipeCommit -cne $env:GITHUB_SHA) { throw 'Input snapshot is not for this workflow checkout' }
if ($GitTag -and $inputs.git.tag -cne $GitTag) { throw 'Requested Git tag differs from original snapshot' }
if ($LfsTag -and $inputs.lfs.tag -cne $LfsTag) { throw 'Requested LFS tag differs from original snapshot' }
$release = Get-BundleRelease $Repository $inputs.releaseTag
$build = $true
if ($null -ne $release) {
    Assert-BundleReleaseInputs $Repository $release $inputs
    if (-not $release.draft) {
        $expected = @(Get-BundleReleaseFileNames $inputs)
        $actual = @($release.assets.name)
        if ($actual.Count -ne $expected.Count -or @($expected | Where-Object { $_ -cnotin $actual }).Count) { throw 'Published release has an incomplete or unexpected asset set' }
        $build = $false
        Write-Host "Published identity already matches: $($release.html_url). No assets will be changed."
    }
}
"release_tag=$($inputs.releaseTag)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
"should_build=$($build.ToString().ToLowerInvariant())" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
