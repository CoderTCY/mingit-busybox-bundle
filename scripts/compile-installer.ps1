# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputsPath, [Parameter(Mandatory)][string]$OutputRoot)
. "$PSScriptRoot/payload.ps1"
$root = Split-Path $PSScriptRoot -Parent
$inputs = Get-Content -LiteralPath $InputsPath -Raw | ConvertFrom-Json
Assert-BundleInputs $inputs $root
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$work = Join-Path $OutputRoot 'work'
$payload = Join-Path $OutputRoot 'payload'
$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$inno = Receive-BundleFile $inputs.toolchain.inno (Join-Path $work "downloads/innosetup-$($inputs.toolchain.inno.version)-x64.exe")
$signature = Get-AuthenticodeSignature -LiteralPath $inno
if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $inputs.toolchain.inno.publisher) {
    throw "Official Inno signature invalid or publisher mismatch: $($signature.Status)"
}
$toolRoot = Join-Path $work 'inno'
$process = Start-Process -FilePath $inno -ArgumentList @('/CURRENTUSER','/PORTABLE=1','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS','/TASKS=',('/DIR="' + $toolRoot + '"')) -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "Official Inno tool installation failed: $($process.ExitCode)" }
$process.Dispose()
$iscc = Join-Path $toolRoot 'ISCC.exe'
$scriptFile = Join-Path $root 'installer/setup.iss'
Invoke-BundleNative $iscc @('/Qp', "/O$dist", "/DPayloadDir=$payload", "/DAppVersion=$($inputs.appVersion)", "/DFileVersion=$($inputs.git.packageVersion)", "/DReleaseTag=$($inputs.releaseTag)", $scriptFile)
$main = Join-Path $dist "MinGit-BusyBox-Bundle-$($inputs.releaseTag)-x64.exe"
if (-not (Test-Path -LiteralPath $main)) { throw 'Inno did not produce the expected sole main installer' }
Copy-Item -LiteralPath $InputsPath -Destination (Join-Path $dist 'inputs.json')
Copy-Item -LiteralPath (Join-Path $payload 'build-manifest.json') -Destination (Join-Path $dist 'build-manifest.json')

# A genuine older Git LFS binary, not a modified version string or mocked file.
$older = $inputs.upgradeFixture.lfs
if ([version]$older.version -ge [version]$inputs.lfs.version) { throw 'Upgrade fixture must use a lower stable LFS version' }
$fixturePayload = Join-Path $work 'upgrade-payload'
if (Test-Path -LiteralPath $fixturePayload) { throw 'Upgrade fixture payload already exists' }
[IO.Directory]::CreateDirectory($fixturePayload) | Out-Null
Get-ChildItem -LiteralPath $payload -Force | Copy-Item -Destination $fixturePayload -Recurse -Force
Set-BundleLfs -Lfs $older -Payload $fixturePayload -Work $work
$fixtureManifest = Get-Content -LiteralPath (Join-Path $fixturePayload 'build-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
$fixtureManifest.inputs.lfs = $older
$fixtureManifest.inputs.releaseTag = 'gfw-{0}-lfs-{1}-r{2}' -f $inputs.git.tag.Substring(1), $older.version, $inputs.recipeCommit.Substring(0,12)
$fixtureManifest.inputs.appVersion = '{0}+lfs.{1}.r{2}' -f $inputs.git.packageVersion, $older.version, $inputs.recipeCommit.Substring(0,12)
$fixtureManifest.components.lfs = $older
$fixtureManifest.isUpgradeFixture = $true
Write-BundlePayloadManifest -Payload $fixturePayload -Manifest $fixtureManifest
$fixtureOutput = Join-Path $work 'fixtures'
[IO.Directory]::CreateDirectory($fixtureOutput) | Out-Null
Invoke-BundleNative $iscc @('/Qp', "/O$fixtureOutput", "/DPayloadDir=$fixturePayload", "/DAppVersion=$($fixtureManifest.inputs.appVersion)", "/DFileVersion=$($inputs.git.packageVersion)", "/DReleaseTag=$($fixtureManifest.inputs.releaseTag)", "/DOutputBaseFilename=Upgrade-Fixture-LFS-$($older.version)-x64", $scriptFile)
Write-Host "Compiled main installer and separate genuine LFS $($older.version) upgrade fixture"
