# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputsPath,
    [Parameter(Mandatory)][string]$SdkRoot,
    [string]$OutputRoot = 'build'
)
. "$PSScriptRoot/common.ps1"
if ($env:GITHUB_ACTIONS -cne 'true') { throw 'LFS compilation and execution are restricted to GitHub Actions' }
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'Native Windows x64 is required'
}
$root = Split-Path $PSScriptRoot -Parent
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
Assert-BundleInputs $inputs $root
$SdkRoot = (Resolve-Path -LiteralPath $SdkRoot).Path
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$work = Join-Path $OutputRoot 'work/lfs-build'
$downloads = Join-Path $OutputRoot 'work/downloads'
$sourceRoot = Join-Path $work 'source'
$git = Join-Path $SdkRoot 'ucrt64/bin/git.exe'
# The SDK package owns this native applet; the product's thin ash.exe wrapper
# is created later by the official MinGit exporter, not by this build script.
$ash = Join-Path $SdkRoot 'ucrt64/libexec/busybox/ash.exe'
$bash = Join-Path $SdkRoot 'usr/bin/bash.exe'
$msgfmt = Join-Path $SdkRoot 'ucrt64/bin/msgfmt.exe'
$tar = Join-Path $env:SystemRoot 'System32/tar.exe'
foreach ($required in @($git, $ash, $bash, $msgfmt, $tar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required build tool is missing: $required" }
}
if (Test-Path -LiteralPath $work) { throw 'LFS build directory already exists; use a fresh CI output directory' }
[IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
$patches = @($inputs.patches | Where-Object path -CEQ 'patches/0005-lfs-core-shell.patch')
if ($patches.Count -ne 1) { throw 'Exactly one reviewed LFS core.shell patch is required' }
$patch = $patches[0]
$patchPath = Join-Path $root $patch.path
if ($inputs.lfs.tag -cne "v$($inputs.lfs.version)" -or $inputs.lfs.commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid LFS source identity' }
if ($inputs.lfs.vendor -cne ('MinGitBusyBoxBundle.r' + $inputs.recipeCommit.Substring(0,12))) { throw 'Invalid custom LFS vendor identity' }
if ($inputs.lfs.source.name -cne "git-lfs-vendor-$($inputs.lfs.tag).tar.gz" -or
    $inputs.lfs.source.url -cne "https://github.com/git-lfs/git-lfs/releases/download/$($inputs.lfs.tag)/$($inputs.lfs.source.name)") {
    throw 'The exact upstream same-version vendor archive is required'
}
$archive = Receive-BundleFile $inputs.lfs.source (Join-Path $downloads $inputs.lfs.source.name)
$goArchive = Receive-BundleFile $inputs.toolchain.go.binary (Join-Path $downloads $inputs.toolchain.go.binary.name)
# Keep the compiler's matching source archive alongside the pristine vendor archive.
$null = Receive-BundleFile $inputs.toolchain.go.source (Join-Path $downloads $inputs.toolchain.go.source.name)
Invoke-BundleNative $tar @('-xf', $archive, '-C', $sourceRoot, '--strip-components=1')
foreach ($required in @('go.mod', 'vendor/modules.txt', 'LICENSE.md', 'config/version.go', 'versioninfo.json', 'docs/man/git-lfs.adoc')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) { throw "Vendor archive lacks $required" }
}
$versionSource = Get-Content -LiteralPath (Join-Path $sourceRoot 'config/version.go') -Raw
$versionMatch = [regex]::Match($versionSource, '(?m)^\s*Version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$')
if (-not $versionMatch.Success -or $versionMatch.Groups[1].Value -cne $inputs.lfs.version) { throw 'Vendor source version differs from locked input' }
$resourceVersion = Get-Content -LiteralPath (Join-Path $sourceRoot 'versioninfo.json') -Raw | ConvertFrom-Json
if ($resourceVersion.StringFileInfo.ProductVersion -cne $inputs.lfs.version) { throw 'Windows resource version differs from locked input' }
$goRequirement = [regex]::Match((Get-Content -LiteralPath (Join-Path $sourceRoot 'go.mod') -Raw), '(?m)^go ([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$')
if (-not $goRequirement.Success -or [version]$inputs.toolchain.go.version -lt [version]$goRequirement.Groups[1].Value) { throw 'Pinned Go does not satisfy go.mod' }
Expand-Archive -LiteralPath $goArchive -DestinationPath (Join-Path $work 'toolchain')
$goRoot = Join-Path $work 'toolchain/go'
$go = Join-Path $goRoot 'bin/go.exe'
Copy-Item -LiteralPath (Join-Path $goRoot 'LICENSE') -Destination (Join-Path $work 'go-LICENSE')

# The generator has one runtime dependency. Build both exact, checksum-verified
# module source ZIPs in an isolated GOPATH: no go install @latest, module resolver,
# or downloads of test-only dependencies. Keep their original go.mod and licenses.
$generatorRoot = Join-Path $work 'generator-source'
$generatorPackages = @($inputs.toolchain.goversioninfo) + @($inputs.toolchain.goversioninfo.dependencies)
foreach ($package in $generatorPackages) {
    $packageArchive = Receive-BundleFile $package.source (Join-Path $downloads $package.source.name)
    $unpack = Join-Path $work ('unpack-' + $package.source.name)
    Expand-Archive -LiteralPath $packageArchive -DestinationPath $unpack
    $packageRoot = Join-Path $unpack "$($package.module)@$($package.version)"
    if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'go.mod'))) { throw "Generator source is missing: $($package.module)" }
    $destination = Join-Path $generatorRoot "src/$($package.module)"
    [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
    Move-Item -LiteralPath $packageRoot -Destination $destination
    Remove-Item -LiteralPath $unpack -Recurse -Force
}
$toolBin = Join-Path $work 'bin'
[IO.Directory]::CreateDirectory($toolBin) | Out-Null
# This standalone builder runs in its own PowerShell process. Its source-test
# environment must never leak into the orchestrator's payload/export steps.
$environmentNames = @('PATH', 'GOROOT', 'GOPATH', 'GOCACHE', 'GOMODCACHE', 'GOTOOLCHAIN', 'GOENV', 'GOFLAGS', 'GOWORK', 'GOPROXY', 'GOSUMDB', 'GO111MODULE', 'GOOS', 'GOARCH', 'GOAMD64', 'GOEXPERIMENT', 'CGO_ENABLED', 'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_CEILING_DIRECTORIES', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_EXEC_PATH', 'SHELL', 'MSYSTEM', 'CHERE_INVOKING')
$environmentNames += @(Get-ChildItem Env: | Where-Object Name -Match '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$' | ForEach-Object Name)
$environmentNames += @('GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
Push-Location $sourceRoot
try {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    # Native builds/tests cannot borrow the SDK's MSYS sh.exe from usr/bin.
    # The separate documentation helper explicitly establishes its SDK PATH.
    $env:PATH = "$toolBin;$(Join-Path $goRoot 'bin');$(Join-Path $SdkRoot 'ucrt64/bin');$env:SystemRoot\System32;$env:SystemRoot"
    $env:GOROOT = $goRoot
    $env:GOPATH = $generatorRoot
    $env:GOCACHE = Join-Path $work 'go-cache'
    $env:GOMODCACHE = Join-Path $work 'module-cache'
    $env:GOTOOLCHAIN = 'local'
    $env:GOENV = 'off'
    $env:GOWORK = 'off'
    $env:GOPROXY = 'off'
    $env:GOSUMDB = 'off'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:GOAMD64 = 'v1'
    $env:CGO_ENABLED = '0'
    $env:GIT_CEILING_DIRECTORIES = $work
    $env:HOME = Join-Path $work 'home'
    $env:USERPROFILE = $env:HOME
    $env:XDG_CONFIG_HOME = Join-Path $env:HOME '.config'
    [IO.Directory]::CreateDirectory($env:HOME) | Out-Null
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = 'NUL'
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'core.shell'
    $env:GIT_CONFIG_VALUE_0 = $ash.Replace('\', '/')
    $actualGit = (Get-Command git.exe -CommandType Application).Source
    if (-not $actualGit.Equals($git, [StringComparison]::OrdinalIgnoreCase)) { throw 'LFS source build did not select the patched SDK Git' }
    $gitVersion = (& $git --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $gitVersion.Contains('.busyboxbundle.' + $inputs.recipeCommit.Substring(0,12))) { throw 'Source tests require this recipe patched SDK Git' }
    $shellPath = (& $git var GIT_SHELL_PATH | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $shellPath.Replace('\', '/').Equals($env:GIT_CONFIG_VALUE_0, [StringComparison]::OrdinalIgnoreCase)) { throw 'Patched Git did not resolve the configured native ash.exe' }
    Invoke-BundleNative $git @('apply', '--check', $patchPath)
    Invoke-BundleNative $git @('apply', $patchPath)
    $compiler = (& $go version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $compiler -cne "go version go$($inputs.toolchain.go.version) windows/amd64") { throw "Unexpected Go compiler: $compiler" }
    $env:GO111MODULE = 'off'
    Invoke-BundleNative $go @('build', '-trimpath', '-o', (Join-Path $toolBin 'goversioninfo.exe'), "$($inputs.toolchain.goversioninfo.module)/cmd/goversioninfo")
    $env:GO111MODULE = 'on'
    $env:GOFLAGS = '-mod=vendor -buildvcs=false'
    # Match upstream FORCE_LOCALIZE: catalogs must be generated, never silently skipped.
    $poBuild = Join-Path $sourceRoot 'po/build'
    [IO.Directory]::CreateDirectory($poBuild) | Out-Null
    $catalogs = @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'po') -Filter '*.po' -File)
    if ($catalogs.Count -eq 0) { throw 'No upstream LFS catalogs were found' }
    foreach ($catalog in $catalogs) {
        Invoke-BundleNative $msgfmt @('-o', (Join-Path $poBuild ($catalog.BaseName + '.mo')), $catalog.FullName)
    }
    # These are the upstream mangen, trgen and Windows resource.syso commands.
    Invoke-BundleNative $go @('generate', 'github.com/git-lfs/git-lfs/v3/commands')
    Invoke-BundleNative $go @('generate', 'github.com/git-lfs/git-lfs/v3/tr')
    Invoke-BundleNative $go @('generate', '.')
    foreach ($generated in @('commands/mancontent_gen.go', 'tr/tr_gen.go', 'resource.syso')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $generated)) -or (Get-Item -LiteralPath (Join-Path $sourceRoot $generated)).Length -eq 0) { throw "Missing generated LFS resource: $generated" }
    }
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    Invoke-BundleNative $bash @('--login', (Join-Path $PSScriptRoot 'build-lfs-docs.sh'), $sourceRoot, $work, $inputs.lfs.tag, $inputs.lfs.commit)
    $documentation = Join-Path $work 'documentation'
    [IO.Directory]::CreateDirectory($documentation) | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'man') -Destination (Join-Path $documentation 'man') -Recurse
    foreach ($document in @('README.md', 'CHANGELOG.md', 'LICENSE.md')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $document) -Destination (Join-Path $documentation $document)
    }
    $binary = Join-Path $work 'git-lfs.exe'
    # Official Makefile BUILD flags and existing config linker fields; do not
    # rewrite config.Version or claim the GitHub vendor for this patched binary.
    $linkerFlags = "-s -w -X github.com/git-lfs/git-lfs/v3/config.Vendor=$($inputs.lfs.vendor) -X github.com/git-lfs/git-lfs/v3/config.GitCommit=$($inputs.lfs.commit)"
    Invoke-BundleNative $go @('build', '-trimpath', '-ldflags', $linkerFlags, '-o', $binary, '.')
    Invoke-BundleNative $go @('test', '-mod=vendor', '-count=1', './subprocess', './ssh', './tq', './lfshttp')
    $versionOutput = (& $binary --version | Out-String).Trim()
    $expectedVersion = "git-lfs/$($inputs.lfs.version) ($($inputs.lfs.vendor); windows amd64; go $($inputs.toolchain.go.version); git $($inputs.lfs.commit))"
    if ($LASTEXITCODE -ne 0 -or $versionOutput -cne $expectedVersion) { throw "Custom LFS version smoke failed: $versionOutput" }
    $metadata = [ordered]@{
        schemaVersion = 1
        tag = $inputs.lfs.tag
        version = $inputs.lfs.version
        commit = $inputs.lfs.commit
        vendor = $inputs.lfs.vendor
        recipeCommit = $inputs.recipeCommit
        source = $inputs.lfs.source
        sourceRoot = 'work/lfs-build/source'
        pristineArchive = 'work/downloads/' + $inputs.lfs.source.name
        patch = $patch
        go = $inputs.toolchain.go
        compiler = $compiler
        goversioninfo = $inputs.toolchain.goversioninfo
        generatorSourceRoot = 'work/lfs-build/generator-source'
        documentationRoot = 'work/lfs-build/documentation'
        documentationToolchain = Get-Content -LiteralPath (Join-Path $work 'documentation-toolchain.txt')
        git = $gitVersion
        sourceTestShell = [IO.Path]::GetRelativePath($SdkRoot, $shellPath).Replace('\', '/')
        sourceTestPackages = @('./subprocess', './ssh', './tq', './lfshttp')
        versionOutput = $versionOutput
        binarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        length = (Get-Item -LiteralPath $binary).Length
    }
    $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $work 'build.json') -Encoding utf8NoBOM
}
finally {
    Pop-Location
}
