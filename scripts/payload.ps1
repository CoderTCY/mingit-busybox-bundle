# SPDX-License-Identifier: GPL-2.0-only
. "$PSScriptRoot/common.ps1"

function Get-BundleLfsRelease {
    param([Parameter(Mandatory)]$Lfs, [Parameter(Mandatory)][string]$Work)
    if ($Lfs.vendor -cne 'GitHub') { throw 'Official LFS binary downloads are only used for the genuine upgrade fixture' }
    $zip = Receive-BundleFile $Lfs (Join-Path $Work "downloads/$($Lfs.name)")
    $unpack = Join-Path $Work "lfs-$($Lfs.version)"
    if (-not (Test-Path -LiteralPath $unpack)) { Expand-Archive -LiteralPath $zip -DestinationPath $unpack }
    $component = Join-Path $unpack "git-lfs-$($Lfs.version)"
    $executables = @(Get-ChildItem -LiteralPath $unpack -Filter 'git-lfs.exe' -File -Recurse)
    $expected = [IO.Path]::GetFullPath((Join-Path $component 'git-lfs.exe'))
    if ($executables.Count -ne 1 -or $executables[0].FullName -ine $expected) { throw 'Unexpected official Git LFS ZIP layout' }
    return $component
}

function Set-BundleLfs {
    param([Parameter(Mandatory)]$Lfs, [Parameter(Mandatory)][string]$Payload, [Parameter(Mandatory)][string]$Work,
          [Parameter(Mandatory)][string]$BinaryPath, [Parameter(Mandatory)][string]$DocumentationPath)
    Copy-Item -LiteralPath $BinaryPath -Destination (Join-Path $Payload 'ucrt64/bin/git-lfs.exe') -Force
    $docs = Join-Path $Payload 'ucrt64/share/doc/git-lfs'
    $licenses = Join-Path $Payload 'ucrt64/share/licenses/git-lfs'
    # These paths are private generated payload trees, never a live installation.
    foreach ($directory in @($docs, $licenses)) {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    foreach ($file in Get-ChildItem -LiteralPath $DocumentationPath -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($DocumentationPath, $file.FullName)
        if ($file.Extension -in @('.md', '.adoc', '.html', '.1', '.5', '.7') -or $relative -match '^man[/\\]') {
            $destination = Join-Path $docs $relative
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
    }
    $source = Receive-BundleFile $Lfs.source (Join-Path $Work "downloads/$($Lfs.source.name)")
    $sourceRoot = Join-Path $Work "lfs-source-$($Lfs.version)"
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
        Invoke-BundleNative (Join-Path $env:SystemRoot 'System32/tar.exe') @('-xzf', $source, '-C', $sourceRoot)
    }
    $roots = @(@($sourceRoot) + @(Get-ChildItem -LiteralPath $sourceRoot -Directory | ForEach-Object FullName) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'LICENSE.md') })
    if ($roots.Count -ne 1) { throw 'Official LFS source archive has no unique root LICENSE.md' }
    $sourceRoot = $roots[0]
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE.md') -Destination $licenses
    $vendor = Join-Path $sourceRoot 'vendor'
    if (-not (Test-Path -LiteralPath $vendor -PathType Container)) { throw 'Official LFS source archive does not include vendor sources' }
    foreach ($notice in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse | Where-Object { $_.Name -match '(?i)^(licen[cs]e|notice|copying|copyright|third[-_ ]party)' }) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $notice.FullName)
        $destination = Join-Path $licenses $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Copy-Item -LiteralPath $notice.FullName -Destination $destination -Force
    }
}

function Write-BundlePayloadManifest {
    param([Parameter(Mandatory)][string]$Payload, [Parameter(Mandatory)]$Manifest)
    $manifestFile = Join-Path $Payload 'build-manifest.json'
    $ownershipFile = Join-Path $Payload 'payload-files.txt'
    $owned = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Payload -File -Recurse | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($Payload, $file.FullName).Replace('\', '/')
        if ($relative -eq 'etc/gitconfig') { continue }
        if ($relative -in @('build-manifest.json', 'payload-files.txt')) { continue }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Payload cannot contain reparse-point files: $relative" }
        $owned.Add($relative)
        $files.Add([ordered]@{ path = $relative; length = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
    $owned.Add('build-manifest.json')
    $owned.Add('payload-files.txt')
    $owned.Sort([StringComparer]::Ordinal)
    $Manifest.files = @($files.ToArray())
    $Manifest | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $manifestFile -Encoding utf8NoBOM
    $owned.ToArray() | Set-Content -LiteralPath $ownershipFile -Encoding utf8NoBOM
}
