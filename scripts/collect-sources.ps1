#requires -Version 7.4
# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$InputsPath
)
. "$PSScriptRoot/common.ps1"
Add-Type -AssemblyName System.Formats.Tar
$PayloadRoot = [IO.Path]::GetFullPath($PayloadRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$SdkRoot = [IO.Path]::GetFullPath($SdkRoot)
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
Assert-BundleInputs -Inputs $inputs -ProjectRoot $ProjectRoot
# A failed run must not make stale files look like complete corresponding source.
if (Test-Path -LiteralPath $OutputDirectory) { throw "Source output already exists; use a fresh output directory: $OutputDirectory" }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$git = Join-Path $SdkRoot 'cmd/git.exe'
$downloads = [Collections.Generic.List[object]]::new()
$lookups = [Collections.Generic.List[object]]::new()
$artifacts = [Collections.Generic.List[object]]::new()
$ownership = [Collections.Generic.List[object]]::new()
$sourcePackages = [Collections.Generic.List[object]]::new()

function Assert-RelativePath([string]$Path) {
    if (-not $Path -or $Path -match '(^[/\\]|[:\\]|(^|/)\.\.(/|$)|(^|/)\.(/|$))') { throw "Unsafe archive/package path: $Path" }
}
function Get-OutputPath([string]$Relative) {
    Assert-RelativePath $Relative
    $path = Join-Path $OutputDirectory $Relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    return $path
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Copy-SourceFile([string]$Source, [string]$Relative, [string]$Origin) {
    $destination = Get-OutputPath $Relative
    if (Test-Path -LiteralPath $destination) { throw "Duplicate source destination: $Relative" }
    Copy-Item -LiteralPath $Source -Destination $destination
    $artifacts.Add([ordered]@{ path = $Relative; origin = $Origin; sha256 = Get-Sha256 $destination })
    return $Relative
}
function Copy-LockedBuildArchive($Asset, [string]$Relative) {
    if ($Asset.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Build source archive has no locked SHA-256' }
    $cached = Join-Path $BuildRoot "work/downloads/$($Asset.name)"
    if ((Get-Sha256 $cached) -cne $Asset.sha256) { throw "Build source cache differs from locked input: $($Asset.name)" }
    Copy-SourceFile $cached $Relative $Asset.url | Out-Null
    $downloads.Add([ordered]@{ path = $Relative; url = $Asset.url; sha256 = $Asset.sha256; expectedSha256 = $Asset.sha256; acquiredBy = 'verified-build-cache' })
}
function Invoke-Git([string[]]$Arguments) {
    $result = @(& $git -c core.autocrlf=false -c core.eol=lf @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Source git command failed ($LASTEXITCODE): $($Arguments -join ' ')" }
    return $result
}
function Export-Commit([string]$Repository, [string]$Commit, [string]$Relative, [string]$Origin) {
    $actual = (Invoke-Git @('-C', $Repository, 'rev-parse', "$Commit^{commit}")) -join ''
    if ($actual -cne $Commit) { throw "Source commit is unavailable: $Origin@$Commit" }
    $path = Get-OutputPath $Relative
    Invoke-Git @('-C', $Repository, 'archive', '--format=zip', "--output=$path", '--prefix=source/', $Commit) | Out-Null
    $artifacts.Add([ordered]@{ path = $Relative; origin = $Origin; commit = $Commit; sha256 = Get-Sha256 $path })
}
function Receive-Source([string]$Url, [string]$Relative, [string]$ExpectedHash = '', [switch]$AllowNotFound) {
    $uri = [Uri]$Url
    if ($uri.Scheme -cne 'https') { throw "Source URL is not HTTPS: $Url" }
    $headers = @{ 'User-Agent' = 'MinGit-BusyBox-Bundle' }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($uri.Host -in @('api.github.com', 'raw.githubusercontent.com')) {
        if ($token) { $headers.Authorization = "Bearer $token" }
        if ($uri.Host -eq 'api.github.com') {
            $headers.Accept = 'application/vnd.github+json'
            $headers['X-GitHub-Api-Version'] = '2022-11-28'
        }
    }
    $destination = Get-OutputPath $Relative
    if (Test-Path -LiteralPath $destination) { throw "Duplicate download destination: $Relative" }
    $partial = "$destination.partial"
    try {
        $response = Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $partial -PassThru -SkipHttpErrorCheck
        $status = [int]$response.StatusCode
        $lookups.Add([ordered]@{ url = $Url; status = $status })
        if ($status -eq 404 -and $AllowNotFound) { return $false }
        if ($status -ne 200) { throw "Source request failed with HTTP $status`: $Url" }
        $actual = Get-Sha256 $partial
        if ($ExpectedHash -and ($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $actual -cne $ExpectedHash.ToLowerInvariant())) {
            throw "Source SHA-256 mismatch: $Url"
        }
        Move-Item -LiteralPath $partial -Destination $destination
        $downloads.Add([ordered]@{ path = $Relative; url = $Url; sha256 = $actual; expectedSha256 = $ExpectedHash })
        return $true
    }
    finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
}
function Read-SourceJson([string]$Relative) {
    # -NoEnumerate preserves a one-element release/assets array as an array.
    return ,(Get-Content -LiteralPath (Join-Path $OutputDirectory $Relative) -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate)
}
function Read-PacmanSections([string]$Path) {
    $sections = @{}
    $section = ''
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -match '^%([A-Z0-9_]+)%$') {
            $section = $Matches[1]
            $sections[$section] = [Collections.Generic.List[string]]::new()
        }
        elseif ($line -and $section) { $sections[$section].Add($line) }
    }
    return $sections
}
function Read-SourceArchive([string]$Relative, [string]$LicensePrefix) {
    # Do not execute upstream PKGBUILDs or unpack untrusted links. TarReader also
    # lets us retain bare VCS caches intact while checking every declared input.
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $materialized = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $texts = @{}
    $hashes = @{}
    $licenses = [Collections.Generic.List[string]]::new()
    $compressed = $null
    $stream = $null
    $reader = $null
    $decoder = $null
    $decoderStarted = $false
    try {
        $archivePath = Join-Path $OutputDirectory $Relative
        if ($Relative.EndsWith('.tar.gz', [StringComparison]::Ordinal)) {
            $compressed = [IO.File]::OpenRead($archivePath)
            $stream = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress)
        } elseif ($Relative.EndsWith('.tar.zst', [StringComparison]::Ordinal)) {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $SdkRoot 'usr/bin/zstd.exe'
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @('--decompress', '--stdout', '--no-progress', '--', $archivePath)) { $start.ArgumentList.Add($argument) }
            $decoder = [Diagnostics.Process]::new()
            $decoder.StartInfo = $start
            $decoderStarted = $decoder.Start()
            if (-not $decoderStarted) { throw 'Cannot start the SDK zstd decoder' }
            $decoderError = $decoder.StandardError.ReadToEndAsync()
            $stream = $decoder.StandardOutput.BaseStream
        } else { throw "Unsupported official source archive format: $Relative" }
        $reader = [System.Formats.Tar.TarReader]::new($stream, $true)
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            $name = $entry.Name -replace '^(\./)+', ''
            $name = $name.TrimEnd('/')
            if (-not $name) { continue }
            Assert-RelativePath $name
            [void]$names.Add($name)
            if ($entry.EntryType -in @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile)) { [void]$materialized.Add($name) }
            if ($null -eq $entry.DataStream) { continue }
            $leaf = ($name -split '/')[-1]
            if ($leaf -in @('.SRCINFO', 'PKGBUILD', 'VERSION', '0001-core-shell.patch', '0003-busybox-unicode.patch')) {
                $buffer = [IO.MemoryStream]::new()
                try {
                    $entry.DataStream.CopyTo($buffer)
                    $bytes = $buffer.ToArray()
                    $hashes[$name] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                    $texts[$name] = [Text.Encoding]::UTF8.GetString($bytes)
                }
                finally { $buffer.Dispose() }
            }
            elseif ($leaf -match '^(?i:licen[cs]e|copying|copyright|notice|authors)(?:[._-].*)?$') {
                $targetRelative = "$LicensePrefix/$name"
                $target = Get-OutputPath $targetRelative
                $out = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $entry.DataStream.CopyTo($out) } finally { $out.Dispose() }
                $licenses.Add($targetRelative)
            }
        }
        # Consume remaining padding/footer so a decoder cannot block on its pipe
        # and compressed-stream integrity errors are not hidden by tar's EOF.
        $stream.CopyTo([IO.Stream]::Null)
        if ($decoder) {
            $decoder.WaitForExit()
            $errorText = $decoderError.GetAwaiter().GetResult()
            if ($decoder.ExitCode -ne 0) { throw "zstd failed ($($decoder.ExitCode)): $errorText" }
            if ($errorText) { Write-Host $errorText }
        }
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($compressed) { $compressed.Dispose() }
        if ($decoder) {
            if ($decoderStarted -and -not $decoder.HasExited) { $decoder.Kill($true); $decoder.WaitForExit() }
            $decoder.Dispose()
        }
    }
    return @{ names = $names; materialized = $materialized; texts = $texts; hashes = $hashes; licenses = $licenses.ToArray() }
}
function Assert-PackageArchive($Archive, [string]$Base, [string]$Version) {
    $infos = @($Archive.texts.Keys | Where-Object { $_ -match '^[^/]+/\.SRCINFO$' })
    if ($infos.Count -ne 1) { throw "Source package $Base/$Version has no unique top-level .SRCINFO" }
    $root = $infos[0].Substring(0, $infos[0].LastIndexOf('/'))
    if (-not $Archive.texts.ContainsKey("$root/PKGBUILD")) { throw "Source package has no PKGBUILD: $Base/$Version" }
    $fields = @{}
    $declared = [Collections.Generic.List[string]]::new()
    foreach ($line in ($Archive.texts[$infos[0]] -split '\r?\n')) {
        if ($line -match '^\s*(pkgbase|pkgver|pkgrel|epoch)\s*=\s*(\S+)\s*$') { $fields[$Matches[1]] = $Matches[2] }
        elseif ($line -match '^\s*source(?:_[A-Za-z0-9_]+)?\s*=\s*(.+?)\s*$') { $declared.Add($Matches[1]) }
    }
    $sourceVersion = "$($fields['pkgver'])-$($fields['pkgrel'])"
    if ($fields.ContainsKey('epoch') -and $fields.epoch -ne '0') { $sourceVersion = "$($fields.epoch):$sourceVersion" }
    if ($fields['pkgbase'] -cne $Base -or $sourceVersion -cne $Version) {
        throw "Source archive identity mismatch: expected $Base $Version, got $($fields['pkgbase']) $sourceVersion"
    }
    foreach ($source in $declared) {
        $name = if ($source.Contains('::')) { $source.Split('::', 2, [StringSplitOptions]::None)[0] }
                else {
                    $url = ($source -split '[#?]', 2)[0].TrimEnd('/')
                    $leaf = ($url -split '/')[-1]
                    if ($source -match '^(git\+|git://)') { $leaf -replace '\.git$', '' } else { $leaf }
                }
        Assert-RelativePath $name
        $entryPath = "$root/$name"
        if (-not $Archive.materialized.Contains($entryPath) -and -not @($Archive.materialized | Where-Object { $_.StartsWith("$entryPath/", [StringComparison]::Ordinal) }).Count) {
            throw "Source package omits declared input '$source': $Base/$Version; refusing a recipe-only archive"
        }
    }
    return $root
}

# Build an exact metadata database. %BASE%, not prefix surgery, determines the
# source package (notably gettext-runtime, gcc-libs and the UCRT Git splits).
$packages = @{}
foreach ($directory in (Get-ChildItem -LiteralPath (Join-Path $SdkRoot 'var/lib/pacman/local') -Directory | Sort-Object Name)) {
    $descPath = Join-Path $directory.FullName 'desc'
    if (-not (Test-Path -LiteralPath $descPath)) { continue }
    $desc = Read-PacmanSections $descPath
    foreach ($required in @('NAME', 'VERSION', 'BASE')) {
        if (-not $desc.ContainsKey($required) -or $desc[$required].Count -ne 1) { throw "Missing/ambiguous %$required% in $descPath" }
    }
    $name = $desc.NAME[0]
    if ($packages.ContainsKey($name)) { throw "Duplicate installed package: $name" }
    $packages[$name] = @{ name = $name; version = $desc.VERSION[0]; base = $desc.BASE[0]; metadata = $directory.FullName; licenses = $(if ($desc.ContainsKey('LICENSE')) { $desc.LICENSE.ToArray() } else { @() }); files = @() }
}
$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$versionsPath = Join-Path $PayloadRoot 'etc/package-versions.txt'
foreach ($line in [IO.File]::ReadLines($versionsPath)) {
    if (-not $line.Trim()) { continue }
    if ($line -notmatch '^(\S+)\s+(\S+)\s*$') { throw "Malformed exporter package version: $line" }
    $name = $Matches[1]; $version = $Matches[2]
    if (-not $packages.ContainsKey($name) -or $packages[$name].version -cne $version) { throw "Exporter/SDK package version mismatch: $line" }
    [void]$selected.Add($name)
}
if ($selected.Count -eq 0) { throw 'Exporter package inventory is empty' }
$moved = @{}
foreach ($line in [IO.File]::ReadLines((Join-Path $PayloadRoot 'etc/libexec-moved.txt'))) {
    $original = $line.Trim()
    Assert-RelativePath $original
    if ($original -notmatch '^ucrt64/libexec/git-core/([^/]+\.exe)$') { throw "Unexpected exporter libexec move: $original" }
    $destination = "ucrt64/bin/$($Matches[1])"
    if ($moved.ContainsKey($destination)) { throw "Duplicate exporter libexec destination: $destination" }
    $moved[$destination] = $original
}
$wrapperPath = 'ucrt64/share/git/git-wrapper.exe'
$wrapperHash = Get-Sha256 (Join-Path $SdkRoot $wrapperPath)
$payloadFiles = @(Get-ChildItem -LiteralPath $PayloadRoot -File -Recurse | Sort-Object FullName)
$neededPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$pending = [Collections.Generic.List[object]]::new()
$generated = @('build-manifest.json', 'payload-files.txt', 'etc/gitconfig', 'etc/gitconfig.bundle', 'etc/package-versions.txt', 'etc/libexec-moved.txt', 'ucrt64/bin/mingit-open.exe', 'ucrt64/share/licenses/mingit-busybox-bundle/COPYING')
foreach ($file in $payloadFiles) {
    $relative = [IO.Path]::GetRelativePath($PayloadRoot, $file.FullName).Replace('\', '/')
    $hash = Get-Sha256 $file.FullName
    if ($relative -in $generated) {
        $ownership.Add([ordered]@{ path = $relative; sha256 = $hash; source = 'project-and-build-extra'; recipeCommit = $inputs.recipeCommit })
        continue
    }
    if ($relative -ceq 'LICENSE.txt') {
        $ownership.Add([ordered]@{ path = $relative; sha256 = $hash; source = 'build-extra'; commit = $inputs.toolchain.buildExtraCommit })
        continue
    }
    if ($relative -ceq 'etc/gitattributes') {
        # git-extra creates this file from its installed post_install heredoc;
        # it is consequently absent from pacman's owned-file inventory.
        $name = 'mingw-w64-ucrt-x86_64-git-extra'
        if (-not $packages.ContainsKey($name)) { throw 'Missing gitattributes generator package' }
        $generator = Join-Path $packages[$name].metadata 'install'
        $scriptText = [IO.File]::ReadAllText($generator)
        $blocks = @([regex]::Matches($scriptText, '(?ms)^[\t ]*cat > "\$ETC_GITATTRIBUTES" <<\\GITATTRIBUTES\r?\n(?<body>.*?)^GITATTRIBUTES\r?$'))
        if ($blocks.Count -ne 1) { throw 'Cannot identify the installed gitattributes generator' }
        $expected = $blocks[0].Groups['body'].Value.Replace("`r`n", "`n").TrimEnd("`n")
        $actual = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").TrimEnd("`n")
        if ($actual -cne $expected) { throw 'Exported gitattributes differs from the exact installed generator' }
        [void]$selected.Add($name)
        $ownership.Add([ordered]@{ path = $relative; sha256 = $hash; source = 'sdk-package-post-install'; package = $name; version = $packages[$name].version; generatorSha256 = Get-Sha256 $generator })
        continue
    }
    if ($relative -ceq 'ucrt64/share/licenses/git-lfs/go-LICENSE') {
        $ownership.Add([ordered]@{ path = $relative; sha256 = $hash; source = 'go-runtime'; version = $inputs.toolchain.go.version })
        continue
    }
    if ($relative -ceq 'ucrt64/bin/git-lfs.exe' -or $relative.StartsWith('ucrt64/share/doc/git-lfs/', [StringComparison]::Ordinal) -or $relative.StartsWith('ucrt64/share/licenses/git-lfs/', [StringComparison]::Ordinal)) {
        $ownership.Add([ordered]@{ path = $relative; sha256 = $hash; source = 'custom-git-lfs'; commit = $inputs.lfs.commit; vendor = $inputs.lfs.vendor; recipeCommit = $inputs.recipeCommit })
        continue
    }
    $sourcePath = $relative
    if ($relative -in @('ucrt64/bin/ash.exe', 'ucrt64/bin/git-remote-http.exe') -and $hash -ceq $wrapperHash) { $sourcePath = $wrapperPath }
    elseif ($moved.ContainsKey($relative)) { $sourcePath = $moved[$relative] }
    [void]$neededPaths.Add($sourcePath)
    $pending.Add(@{ path = $relative; sha256 = $hash; sdkPath = $sourcePath })
}
$owners = @{}
foreach ($package in ($packages.Values | Sort-Object name)) {
    $filesPath = Join-Path $package.metadata 'files'
    if (-not (Test-Path -LiteralPath $filesPath)) { throw "Missing pacman file inventory for $($package.name)" }
    $sections = Read-PacmanSections $filesPath
    if (-not $sections.ContainsKey('FILES')) {
        # Pacman represents a fileless metapackage with an empty files record.
        # Every actual payload path still has to resolve to an owner below.
        if ([IO.File]::ReadAllText($filesPath).Trim().Length -ne 0) { throw "Invalid file inventory for $($package.name)" }
        continue
    }
    $package.files = $sections.FILES.ToArray()
    foreach ($path in $package.files) {
        if ($neededPaths.Contains($path)) {
            if ($owners.ContainsKey($path)) { throw "Ambiguous SDK file ownership: $path" }
            $owners[$path] = $package.name
        }
    }
}
foreach ($file in $pending) {
    if (-not $owners.ContainsKey($file.sdkPath)) { throw "No corresponding-source owner for payload file: $($file.path) (SDK $($file.sdkPath))" }
    $name = $owners[$file.sdkPath]
    [void]$selected.Add($name)
    $ownership.Add([ordered]@{ path = $file.path; sha256 = $file.sha256; sdkPath = $file.sdkPath; package = $name; version = $packages[$name].version })
}

# Keep all reconstruction inputs alongside the actual source archives, not links.
Copy-SourceFile $InputsPath 'recipe/inputs.json' 'locked-build-inputs' | Out-Null
Copy-SourceFile (Join-Path $PayloadRoot 'build-manifest.json') 'recipe/build-manifest.json' 'shipped-payload' | Out-Null
Copy-SourceFile $versionsPath 'recipe/package-versions.txt' 'exporter-package-inventory' | Out-Null
Copy-SourceFile (Join-Path $PayloadRoot 'etc/libexec-moved.txt') 'recipe/libexec-moved.txt' 'exporter-relocations' | Out-Null
foreach ($patch in $inputs.patches) { Copy-SourceFile (Join-Path $ProjectRoot $patch.path) "recipe/$($patch.path)" 'locked-project-patch' | Out-Null }
Copy-SourceFile (Join-Path $BuildRoot 'work/package-recipe/PKGBUILD') 'recipe/PKGBUILD' 'adapted-package-recipe' | Out-Null
Copy-SourceFile (Join-Path $BuildRoot 'work/busybox-package-recipe/PKGBUILD') 'recipe/busybox/PKGBUILD' 'adapted-busybox-package-recipe' | Out-Null
Copy-SourceFile (Join-Path $BuildRoot 'work/lfs-build/build.json') 'recipe/lfs-build.json' 'custom-lfs-build-record' | Out-Null
Copy-SourceFile (Join-Path $BuildRoot 'work/lfs-build/documentation-toolchain.txt') 'recipe/lfs-documentation-toolchain.txt' 'sdk-documentation-tools' | Out-Null
Export-Commit $ProjectRoot $inputs.recipeCommit 'recipe/project.zip' 'project-recipe'
Export-Commit (Join-Path $BuildRoot 'work/build-extra') $inputs.toolchain.buildExtraCommit 'recipe/build-extra.zip' 'https://github.com/git-for-windows/build-extra'
Export-Commit (Join-Path $BuildRoot 'work/MINGW-packages') $inputs.toolchain.mingwPackagesCommit 'recipe/MINGW-packages.zip' 'https://github.com/git-for-windows/MINGW-packages'
# This human-readable tree supplements (never replaces) this build's --allsource
# archive, whose bare Git cache, wrappers and adapted PKGBUILD remain untouched.
Export-Commit (Join-Path $BuildRoot 'work/package-recipe/git') $inputs.git.commit 'git/git-source.zip' 'https://github.com/git-for-windows/git'
Export-Commit (Join-Path $BuildRoot 'work/busybox-package-recipe/busybox-w32') $inputs.toolchain.busybox.commit 'busybox/busybox-source.zip' 'https://github.com/git-for-windows/busybox-w32'

$releaseCache = @{}
$indexCache = @{}
function Find-IndexedSource([string[]]$BinaryNames, [string]$Base, [string]$Version, [string[]]$FileNames, [string]$DestinationDirectory) {
    $indexes = [Collections.Generic.List[string]]::new()
    foreach ($binary in $BinaryNames) {
        if (-not $indexes.Contains($binary)) { $indexes.Add($binary) }
    }
    # Upstream uploads a shared source tarball once, sometimes with its MINGW64
    # build rather than the later UCRT binary release. Consult only same-version
    # source indexes; no binary from another architecture is ever downloaded.
    $ucrtPrefix = 'mingw-w64-ucrt-x86_64-'
    foreach ($binary in $BinaryNames) {
        if ($binary.StartsWith($ucrtPrefix, [StringComparison]::Ordinal)) {
            $shared = 'mingw-w64-x86_64-' + $binary.Substring($ucrtPrefix.Length)
            if (-not $indexes.Contains($shared)) { $indexes.Add($shared) }
        }
    }
    $baseIndex = if ($Base.StartsWith('mingw-w64-', [StringComparison]::Ordinal)) { 'mingw-w64-x86_64-' + $Base.Substring('mingw-w64-'.Length) } else { $Base }
    if (-not $indexes.Contains($baseIndex)) { $indexes.Add($baseIndex) }
    foreach ($binary in $indexes) {
        if (-not $indexCache.ContainsKey($binary)) {
            $relative = "metadata/indexes/$binary.versions.json"
            $url = "https://raw.githubusercontent.com/git-for-windows/pacman-repo/refs/heads/x86_64/$binary.versions.json"
            $indexCache[$binary] = if (Receive-Source $url $relative -AllowNotFound) { Read-SourceJson $relative } else { $null }
        }
        $index = $indexCache[$binary]
        if ($null -eq $index) { continue }
        if ($index -isnot [Collections.IDictionary]) { throw "Invalid versions index for $binary" }
        if (-not $index.Contains($Version)) { continue }
        $tags = @($index[$Version])
        if ($tags.Count -eq 0) { throw "Empty indexed release for $binary $Version" }
        foreach ($tag in ($tags | Sort-Object -Unique)) {
            if ($tag -isnot [string] -or -not $tag) { throw "Invalid indexed release tag for $binary $Version" }
            if (-not $releaseCache.ContainsKey($tag)) {
                $encoded = [Uri]::EscapeDataString($tag)
                $releaseRelative = "metadata/releases/$encoded/release.json"
                Receive-Source "https://api.github.com/repos/git-for-windows/pacman-repo/releases/tags/$encoded" $releaseRelative | Out-Null
                $release = Read-SourceJson $releaseRelative
                if ($release -isnot [Collections.IDictionary] -or -not $release.Contains('id') -or $release.tag_name -cne $tag) { throw "Invalid indexed release metadata: $tag" }
                $assets = [Collections.Generic.List[object]]::new()
                for ($page = 1; ; $page++) {
                    $pageRelative = 'metadata/releases/{0}/assets-{1:d4}.json' -f $encoded, $page
                    Receive-Source "https://api.github.com/repos/git-for-windows/pacman-repo/releases/$($release.id)/assets?per_page=100&page=$page" $pageRelative | Out-Null
                    $batch = Read-SourceJson $pageRelative
                    if ($batch -isnot [array]) { throw "Release asset API did not return an array: $tag page $page" }
                    foreach ($asset in $batch) { $assets.Add($asset) }
                    if ($batch.Count -lt 100) { break }
                }
                $releaseCache[$tag] = $assets.ToArray()
            }
            foreach ($fileName in $FileNames) {
                $matching = @($releaseCache[$tag] | Where-Object { $_.name -ceq $fileName })
                if ($matching.Count -gt 1) { throw "Ambiguous source assets for $Base $Version in $tag" }
                if ($matching.Count -eq 0) { continue }
                $asset = $matching[0]
                if ($asset.state -cne 'uploaded') { throw "Source asset is not uploaded: $fileName" }
                $expected = ''
                if ($asset.Contains('digest') -and $asset.digest) {
                    if ($asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw "Unsupported source asset digest: $fileName" }
                    $expected = $Matches[1]
                }
                $destination = "$DestinationDirectory/$fileName"
                Receive-Source $asset.browser_download_url $destination $expected | Out-Null
                return [ordered]@{ method = 'pacman-repo'; binaryIndex = $binary; releaseTag = $tag; assetId = $asset.id; url = $asset.browser_download_url; archive = $destination }
            }
        }
    }
    return $null
}

$groups = @{}
foreach ($name in ($selected | Sort-Object)) {
    $package = $packages[$name]
    if ($package.base -notmatch '^[A-Za-z0-9_+.-]+$' -or $package.version -notmatch '^(?:[0-9]+:)?[A-Za-z0-9_+.~-]+$') { throw "Unsafe package identity: $name" }
    $key = "$($package.base) $($package.version)"
    if (-not $groups.ContainsKey($key)) { $groups[$key] = [Collections.Generic.List[object]]::new() }
    $groups[$key].Add($package)
    Copy-SourceFile (Join-Path $package.metadata 'desc') "metadata/pacman/$name/desc" 'sdk-pacman-metadata' | Out-Null
    Copy-SourceFile (Join-Path $package.metadata 'files') "metadata/pacman/$name/files" 'sdk-pacman-metadata' | Out-Null
    $installScript = Join-Path $package.metadata 'install'
    if (Test-Path -LiteralPath $installScript) {
        Copy-SourceFile $installScript "metadata/pacman/$name/install" 'sdk-package-post-install' | Out-Null
    }
    # Preserve the notices actually shipped in the payload. The SDK subset may
    # deliberately omit unrelated package documentation such as AUTHORS files;
    # the complete source archive is collected independently below.
    foreach ($license in ($package.files | Where-Object { $neededPaths.Contains($_) -and $_ -notmatch '/$' -and $_ -match '(^|/)(?:licenses?/|(?i:licen[cs]e|copying|copyright|notice|authors)(?:[._-][^/]*)?$)' })) {
        Assert-RelativePath $license
        Copy-SourceFile (Join-Path $SdkRoot $license) "licenses/installed/$name/$license" "sdk-package:$name@$($package.version)" | Out-Null
    }
}
$customPackages = @{
    'mingw-w64-git' = @{
        version = "$($inputs.git.packageVersion)-1"
        commit = $inputs.git.commit
        recipe = 'work/package-recipe/PKGBUILD'
        commitRecord = 'work/git-source-commit.txt'
        patch = '0001-core-shell.patch'
        vcsSource = "git::git+https://github.com/git-for-windows/git.git#commit=$($inputs.git.commit)"
    }
    'mingw-w64-busybox' = @{
        version = "$($inputs.toolchain.busybox.version).busyboxbundle.$($inputs.recipeCommit.Substring(0,12))-1"
        commit = $inputs.toolchain.busybox.commit
        recipe = 'work/busybox-package-recipe/PKGBUILD'
        commitRecord = 'work/busybox-source-commit.txt'
        patch = '0003-busybox-unicode.patch'
        vcsSource = "busybox-w32::git+https://github.com/git-for-windows/busybox-w32.git#commit=$($inputs.toolchain.busybox.commit)"
    }
}
$customSourceCount = 0
foreach ($key in ($groups.Keys | Sort-Object)) {
    $group = @($groups[$key] | Sort-Object name)
    $base = $group[0].base; $version = $group[0].version
    # Epoch is part of the identity, but pacman's source filename omits it.
    $stem = "$base-$($version -replace '^\d+:', '').src.tar"
    $fileNames = @("$stem.gz", "$stem.zst")
    $fileName = $fileNames[0]
    $segment = [Uri]::EscapeDataString($version)
    $directory = "packages/$base/$segment"
    $relative = "$directory/$fileName"
    if ($customPackages.ContainsKey($base)) {
        $custom = $customPackages[$base]
        if ($version -cne $custom.version) { throw "$base package version is not this build: $version" }
        $allsource = @(Get-ChildItem -LiteralPath (Join-Path $BuildRoot 'work/sources') -File | Where-Object Name -CEQ $fileName)
        if ($allsource.Count -ne 1) { throw "Missing this build's unique --allsource archive: $fileName" }
        if ((Get-Content -LiteralPath (Join-Path $BuildRoot $custom.commitRecord) -Raw).Trim() -cne $custom.commit) { throw "$base allsource build commit differs from inputs" }
        Copy-SourceFile $allsource[0].FullName $relative 'this-build:makepkg-mingw --allsource' | Out-Null
        $origin = [ordered]@{ method = 'custom-allsource'; commit = $custom.commit; recipeCommit = $inputs.recipeCommit }
        $customSourceCount++
    }
    else {
        $origin = Find-IndexedSource @($group.name) $base $version $fileNames $directory
        if ($null -eq $origin) {
            $kind = if ($base.StartsWith('mingw-w64-', [StringComparison]::Ordinal)) { 'mingw' } else { 'msys' }
            $roots = @("https://repo.msys2.org/$kind/sources", 'https://wingit.blob.core.windows.net/sources')
            foreach ($sourceRoot in $roots) {
                foreach ($candidate in $fileNames) {
                    $url = "$sourceRoot/$candidate"
                    $destination = "$directory/$candidate"
                    if (Receive-Source $url $destination -AllowNotFound) {
                        $origin = [ordered]@{ method = 'exact-version-fallback'; url = $url; archive = $destination }
                        break
                    }
                }
                if ($null -ne $origin) { break }
            }
            if ($null -eq $origin) { throw "No exact corresponding source for $base $version (binary packages: $($group.name -join ', '))" }
        }
        $relative = $origin.archive
    }
    $archive = Read-SourceArchive $relative "licenses/sources/$base/$segment"
    $root = Assert-PackageArchive $archive $base $version
    if ($customPackages.ContainsKey($base)) {
        if ($archive.hashes["$root/PKGBUILD"] -cne (Get-Sha256 (Join-Path $BuildRoot $custom.recipe))) { throw "$base allsource PKGBUILD is not this build recipe" }
        $sourcePatch = @($inputs.patches | Where-Object path -CEQ "patches/$($custom.patch)")[0]
        if ($archive.hashes["$root/$($custom.patch)"] -cne $sourcePatch.sha256) { throw "$base allsource patch does not match the locked patch" }
        if ($archive.texts["$root/.SRCINFO"] -notmatch ('(?m)^\s*source\s*=\s*' + [regex]::Escape($custom.vcsSource) + '\s*$')) { throw "$base allsource VCS source is not the locked commit" }
    }
    $sourcePackages.Add([ordered]@{ base = $base; version = $version; binaryPackages = @($group.name); declaredLicenses = @($group.licenses | Sort-Object -Unique); archive = $relative; sha256 = Get-Sha256 (Join-Path $OutputDirectory $relative); origin = $origin; extractedLicenses = @($archive.licenses | Sort-Object) })
}
if ($customSourceCount -ne $customPackages.Count) { throw 'Payload must include unique custom Git and BusyBox source packages' }

$lfsRelative = "lfs/$($inputs.lfs.source.name)"
Assert-RelativePath $lfsRelative
if ($inputs.lfs.source.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'LFS vendor source has no locked SHA-256' }
Copy-LockedBuildArchive $inputs.lfs.source $lfsRelative
$lfsArchive = Read-SourceArchive $lfsRelative 'licenses/lfs'
$lfsRoots = @($lfsArchive.names | Where-Object { $_ -match '^(?:[^/]+/)?LICENSE\.md$' })
if ($lfsRoots.Count -ne 1) { throw 'Locked LFS source has no unique root license' }
$lfsPrefix = $lfsRoots[0].Substring(0, $lfsRoots[0].Length - 'LICENSE.md'.Length)
if (-not @($lfsArchive.names | Where-Object { $_.StartsWith("${lfsPrefix}vendor/", [StringComparison]::Ordinal) -and $_ -match '/[^/]+/[^/]+$' }).Count) { throw 'Locked LFS source is missing vendored dependencies' }
# Its pinned official SHA-256 establishes version identity, not an assumed tar
# prefix convention (release archives need not use GitHub's auto-source name).
$lfsBuild = Get-Content -LiteralPath (Join-Path $BuildRoot 'work/lfs-build/build.json') -Raw | ConvertFrom-Json
$lfsPatch = @($inputs.patches | Where-Object path -CEQ 'patches/0005-lfs-core-shell.patch')[0]
if ($lfsBuild.commit -cne $inputs.lfs.commit -or $lfsBuild.vendor -cne $inputs.lfs.vendor -or $lfsBuild.recipeCommit -cne $inputs.recipeCommit -or
    $lfsBuild.source.sha256 -cne $inputs.lfs.source.sha256 -or $lfsBuild.patch.sha256 -cne $lfsPatch.sha256 -or
    $lfsBuild.binarySha256 -cne (Get-Sha256 (Join-Path $PayloadRoot 'ucrt64/bin/git-lfs.exe'))) { throw 'Shipped LFS does not match its custom source build record' }
if (($lfsBuild.go | ConvertTo-Json -Depth 10 -Compress) -cne ($inputs.toolchain.go | ConvertTo-Json -Depth 10 -Compress) -or
    ($lfsBuild.goversioninfo | ConvertTo-Json -Depth 10 -Compress) -cne ($inputs.toolchain.goversioninfo | ConvertTo-Json -Depth 10 -Compress)) { throw 'LFS build toolchain differs from locked source inputs' }

$goRelative = "go/$($inputs.toolchain.go.source.name)"
Copy-LockedBuildArchive $inputs.toolchain.go.source $goRelative
$goArchive = Read-SourceArchive $goRelative 'licenses/go'
if (($goArchive.texts['go/VERSION'] -split '\r?\n')[0] -cne "go$($inputs.toolchain.go.version)") { throw 'Go runtime source version differs from the compiler' }
$goLicense = Join-Path $OutputDirectory 'licenses/go/go/LICENSE'
if ((Get-Sha256 $goLicense) -cne (Get-Sha256 (Join-Path $PayloadRoot 'ucrt64/share/licenses/git-lfs/go-LICENSE'))) { throw 'Shipped Go runtime license differs from its exact source' }

$generatorSources = @()
foreach ($generator in @($inputs.toolchain.goversioninfo) + @($inputs.toolchain.goversioninfo.dependencies)) {
    $relative = "build-tools/$($generator.source.name)"
    Copy-LockedBuildArchive $generator.source $relative
    $generatorSources += [ordered]@{ module = $generator.module; version = $generator.version; source = $generator.source; archive = $relative }
}
$generatorRoot = Join-Path $BuildRoot 'work/lfs-build/generator-source'
foreach ($notice in Get-ChildItem -LiteralPath $generatorRoot -File -Recurse | Where-Object { $_.Name -match '(?i)^(licen[cs]e|notice|copying|copyright|patents)([._-].*)?$' }) {
    $relative = [IO.Path]::GetRelativePath($generatorRoot, $notice.FullName).Replace('\', '/')
    Copy-SourceFile $notice.FullName "licenses/build-tools/$relative" 'locked-lfs-resource-generator-source' | Out-Null
}

# Inventory hashes include copied notices, SDK evidence and downloaded API/index
# JSON. The manifest cannot hash itself; SHA256SUMS below covers it separately.
$files = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = [IO.Path]::GetRelativePath($OutputDirectory, $_.FullName).Replace('\', '/'); size = $_.Length; sha256 = Get-Sha256 $_.FullName }
})
$manifest = [ordered]@{
    schemaVersion = 1
    releaseTag = $inputs.releaseTag
    recipeCommit = $inputs.recipeCommit
    gitCommit = $inputs.git.commit
    busyboxCommit = $inputs.toolchain.busybox.commit
    sourcePolicy = 'Exact SDK %BASE% + %VERSION%, all shipped file owners plus exporter inventory; no version substitutions; archives retain source caches and licenses.'
    reconstruction = @('recipe/project.zip is the pinned project, including native helper, installer and build sources.', 'recipe/inputs.json and recipe/patches contain all five patches and exact inputs; recipe/PKGBUILD and recipe/busybox/PKGBUILD are the adapted recipes.', 'The custom Git and BusyBox packages are this build makepkg --allsource outputs, including their bare VCS caches; git/git-source.zip and busybox/busybox-source.zip additionally provide the unmodified pinned working trees.', 'recipe/build-extra.zip and recipe/MINGW-packages.zip are fixed upstream packaging source trees.', 'Dependency source archives retain their upstream PKGBUILD, .SRCINFO, source files and VCS caches.', 'Custom LFS is rebuilt from its pristine release vendor archive plus patch 0005; recipe/lfs-build.json records the exact binary, source, generated-resource tools and Go compiler. Matching Go runtime source and resource-generator sources are included under go/ and build-tools/.')
    packages = $sourcePackages.ToArray()
    lfs = [ordered]@{ tag = $inputs.lfs.tag; commit = $inputs.lfs.commit; vendor = $inputs.lfs.vendor; source = $inputs.lfs.source; archive = $lfsRelative; patch = $lfsPatch; buildRecord = 'recipe/lfs-build.json'; extractedLicenses = @($lfsArchive.licenses | Sort-Object) }
    go = [ordered]@{ version = $inputs.toolchain.go.version; source = $inputs.toolchain.go.source; archive = $goRelative; extractedLicenses = @($goArchive.licenses | Sort-Object) }
    lfsBuildTools = $generatorSources
    payloadOwnership = @($ownership | Sort-Object path)
    downloads = @($downloads | Sort-Object path)
    lookups = @($lookups | Sort-Object url)
    localArtifacts = @($artifacts | Sort-Object path)
    files = $files
}
$manifestPath = Get-OutputPath 'source-provenance.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 40) + "`n", [Text.UTF8Encoding]::new($false))
$sums = @($files | ForEach-Object { "$($_.sha256)  $($_.path)" }) + "$(Get-Sha256 $manifestPath)  source-provenance.json"
[IO.File]::WriteAllText((Get-OutputPath 'SHA256SUMS'), (($sums | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Complete corresponding source tree: $OutputDirectory"
