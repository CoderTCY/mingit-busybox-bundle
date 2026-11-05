# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputsPath,
    [Parameter(Mandatory)][string]$ArtifactsDir,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$EvidenceRoot
)
. "$PSScriptRoot/release-state.ps1"
Assert-BundleRepository $Repository
$root = Split-Path $PSScriptRoot -Parent
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
Assert-BundleInputs $inputs $root
$names = @(Get-BundleReleaseFileNames $inputs)

# Never run a write-token job against pull-request code or a manual feature ref.
# The YAML gate and these server-side run checks are independent safeguards.
if ($env:GITHUB_ACTIONS -cne 'true' -or $Repository -cne $env:GITHUB_REPOSITORY -or $env:GITHUB_EVENT_NAME -cnotin @('schedule', 'workflow_dispatch') -or $env:GITHUB_RUN_ID -notmatch '^\d+$') { throw 'Publishing requires a trusted scheduled/manual Actions run' }
$repositoryInfo = Get-BundleApi "repos/$Repository"
$run = Get-BundleApi "repos/$Repository/actions/runs/$($env:GITHUB_RUN_ID)"
if ($env:GITHUB_REF -cne "refs/heads/$($repositoryInfo.default_branch)" -or $run.head_branch -cne $repositoryInfo.default_branch -or $run.event -cne $env:GITHUB_EVENT_NAME -or $run.head_sha -cne $inputs.recipeCommit -or $env:GITHUB_SHA -cne $inputs.recipeCommit -or $run.repository.full_name -cne $Repository) { throw 'Publish run is not the fixed recipe on the trusted default branch' }

function Assert-TagCommit {
    param([switch]$Required)
    $refs = @(Get-BundleApi "repos/$Repository/git/matching-refs/tags/$([Uri]::EscapeDataString($inputs.releaseTag))")
    $exact = @($refs | Where-Object ref -CEQ "refs/tags/$($inputs.releaseTag)")
    if ($exact.Count -eq 0 -and -not $Required) { return }
    if ($exact.Count -ne 1) { throw 'Release tag is missing or ambiguous' }
    $object = $exact[0].object
    $seen = [Collections.Generic.HashSet[string]]::new()
    while ($object.type -ceq 'tag') {
        if (-not $seen.Add($object.sha)) { throw 'Cyclic release tag' }
        $object = (Get-BundleApi "repos/$Repository/git/tags/$($object.sha)").object
    }
    if ($object.type -cne 'commit' -or $object.sha -cne $inputs.recipeCommit) { throw 'Release tag points at a different recipe commit' }
}

$release = Get-BundleRelease $Repository $inputs.releaseTag
if ($null -ne $release) {
    Assert-BundleReleaseInputs $Repository $release $inputs
    Assert-TagCommit -Required:(-not $release.draft)
    if (-not $release.draft) {
        if (@($release.assets).Count -ne $names.Count -or @($names | Where-Object { $_ -cnotin @($release.assets.name) }).Count) { throw 'Published release asset set is incomplete or unexpected' }
        Write-Host "Already published with identical fixed inputs: $($release.html_url). Leaving every asset unchanged."
        return
    }
} else { Assert-TagCommit }

$ArtifactsDir = [IO.Path]::GetFullPath($ArtifactsDir)
$actualFiles = @(Get-ChildItem -LiteralPath $ArtifactsDir -Force)
if ($actualFiles.Count -ne $names.Count -or @($actualFiles | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $names -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) { throw 'Release directory must contain exactly the five public assets; upgrade fixtures and logs belong in workflow artifacts' }
foreach ($name in $names) {
    $file = Join-Path $ArtifactsDir $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw "Missing or empty release asset: $name" }
}
$manifest = Get-Content -LiteralPath (Join-Path $ArtifactsDir 'build-manifest.json') -Raw | ConvertFrom-Json
Assert-BundleSameInputs $inputs $manifest.inputs
Assert-BundleSameInputs $inputs (Get-Content -LiteralPath (Join-Path $ArtifactsDir 'inputs.json') -Raw | ConvertFrom-Json)

$hashes = @{}
foreach ($line in (Get-Content -LiteralPath (Join-Path $ArtifactsDir 'SHA256SUMS'))) {
    if ($line -cnotmatch '^([0-9a-fA-F]{64}) [ *]([^/\\]+)$') { throw 'Malformed SHA256SUMS entry' }
    $hash = $Matches[1].ToLowerInvariant()
    $name = $Matches[2]
    if ($name -ceq 'SHA256SUMS' -or $name -cnotin $names -or $hashes.ContainsKey($name)) { throw 'Unexpected or duplicate checksum filename' }
    if ((Get-FileHash -LiteralPath (Join-Path $ArtifactsDir $name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw "Release checksum mismatch: $name" }
    $hashes[$name] = $hash
}
if ($hashes.Count -ne $names.Count - 1) { throw 'SHA256SUMS must cover every other release asset' }
$hashes['SHA256SUMS'] = (Get-FileHash -LiteralPath (Join-Path $ArtifactsDir 'SHA256SUMS') -Algorithm SHA256).Hash.ToLowerInvariant()
$sources = [IO.Compression.ZipFile]::OpenRead((Join-Path $ArtifactsDir 'sources.zip'))
try { if ($sources.Entries.Count -eq 0) { throw 'The corresponding-source archive is empty' } } finally { $sources.Dispose() }

foreach ($scope in @('CurrentUser', 'AllUsers')) {
    $scopeRoot = Join-Path $EvidenceRoot $scope
    $orchestration = Get-Content -LiteralPath (Join-Path $scopeRoot 'verify-evidence.json') -Raw | ConvertFrom-Json
    $lifecycle = Get-Content -LiteralPath (Join-Path $scopeRoot 'lifecycle/installer-evidence.json') -Raw | ConvertFrom-Json
    $payload = Get-Content -LiteralPath (Join-Path $scopeRoot 'lifecycle/payload/payload-evidence.json') -Raw | ConvertFrom-Json
    if ($orchestration.passed -cne $true -or $orchestration.scope -cne $scope -or $orchestration.childExitCode -ne 0 -or $lifecycle.passed -cne $true -or $lifecycle.fullAcceptance -cne $true -or $lifecycle.scope -cne $scope -or $payload.passed -cne $true) { throw "Incomplete acceptance evidence for $scope" }
    if ($lifecycle.releaseTag -cne $inputs.releaseTag -or $lifecycle.installerSha256 -cne $hashes[$names[0]]) { throw "Acceptance evidence belongs to different installer bytes: $scope" }
    if ($scope -ceq 'CurrentUser' -and ($lifecycle.elevated -cne $false -or [string]::IsNullOrWhiteSpace($orchestration.restrictedAccount))) { throw 'CurrentUser acceptance did not prove a restricted account' }
    if ($scope -ceq 'AllUsers' -and $lifecycle.elevated -cne $true) { throw 'AllUsers acceptance did not run elevated' }
    Assert-BundleSameInputs $inputs (Get-Content -LiteralPath (Join-Path $scopeRoot 'offline-artifacts/inputs.json') -Raw | ConvertFrom-Json)
}

if ($null -eq $release) {
    $notes = @"
Unofficial, unsigned custom Windows x64 offline installer. Git, BusyBox, Git LFS, offline HTML manuals and native translations are integrated into the single EXE. This is not an official Git for Windows release.

Git: $($inputs.git.tag); Git LFS: $($inputs.lfs.tag); recipe: $($inputs.recipeCommit).
CurrentUser and AllUsers lifecycle, isolated payload, LFS roundtrip, offline browser help and localization gates passed in https://github.com/$Repository/actions/runs/$($env:GITHUB_RUN_ID).

The other attachments are fixed inputs, provenance, SHA-256 checksums and corresponding source, not separate installers. The installer is not code-signed and may trigger Windows SmartScreen.
"@
    # Bind subsequent mutations to the ID returned by creation. A just-created
    # draft need not already be discoverable through the paginated release list.
    $created = & gh api --method POST "repos/$Repository/releases" --raw-field "tag_name=$($inputs.releaseTag)" --raw-field "target_commitish=$($inputs.recipeCommit)" --field 'draft=true' --raw-field "name=MinGit BusyBox Bundle $($inputs.appVersion)" --raw-field "body=$notes"
    if ($LASTEXITCODE -ne 0) { throw "Release creation failed with exit code $LASTEXITCODE" }
    $release = ($created -join "`n") | ConvertFrom-Json
    if ($release.draft -cne $true -or $release.id -le 0 -or $release.tag_name -cne $inputs.releaseTag -or $release.target_commitish -cne $inputs.recipeCommit) { throw 'Created draft identity differs from the fixed inputs' }
}
$releaseId = $release.id
# Original input identity is uploaded first. A draft without that snapshot
# fails closed; a matching snapshot permits resuming a partial asset upload.
foreach ($name in @('inputs.json', 'build-manifest.json', 'sources.zip', $names[0], 'SHA256SUMS')) {
    $current = Get-BundleApi "repos/$Repository/releases/$releaseId"
    if (-not $current.draft -or $current.tag_name -cne $inputs.releaseTag) { throw 'Release ceased to be the expected draft; refusing to overwrite assets' }
    Invoke-BundleNative 'gh' @('release', 'upload', $inputs.releaseTag, (Join-Path $ArtifactsDir $name), '--repo', $Repository, '--clobber')
}
$release = Get-BundleApi "repos/$Repository/releases/$releaseId"
if (-not $release.draft -or $release.id -ne $releaseId -or @($release.assets).Count -ne $names.Count -or @($names | Where-Object { $_ -cnotin @($release.assets.name) }).Count) { throw 'Draft release asset set is not exact' }
Assert-BundleReleaseInputs $Repository $release $inputs
# GitHub may defer creating a draft's tag until publication.
Assert-TagCommit
$download = Join-Path $env:RUNNER_TEMP ('release-check-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($download) | Out-Null
try {
    foreach ($name in $names) {
        $path = Join-Path $download $name
        Receive-BundleReleaseAsset $Repository $release $name $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$name]) { throw "Uploaded draft asset differs: $name" }
        Remove-Item -LiteralPath $path -Force
    }
    Invoke-BundleNative 'gh' @('release', 'edit', $inputs.releaseTag, '--repo', $Repository, '--draft=false')
    $published = Get-BundleApi "repos/$Repository/releases/$releaseId"
    if ($published.draft -or $published.id -ne $releaseId) { throw 'Release did not become public' }
    Assert-TagCommit -Required
    $installer = Join-Path $download $names[0]
    Receive-BundleReleaseAsset $Repository $published $names[0] $installer
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$names[0]]) { throw 'Public installer download differs from SHA256SUMS' }
    Write-Host "Published and downloaded installer SHA-256 verified: $($published.html_url)"
} finally { Remove-Item -LiteralPath $download -Recurse -Force }
