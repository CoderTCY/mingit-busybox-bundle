# Collected only after a real clone failure; no probe substitutes for that gate.
# Run by GitHub Actions under the same token/environment as the failed command.
function Save-TransportDiagnostics([string] $Root, [string] $Source, [string] $Transport) {
    $evidencePath = Join-Path $script:RunRoot "transport-$Transport-diagnostics.json"
    $evidence = [ordered]@{ source = $Source; transport = $Transport; identity = $null; environment = @{}; metadataComparison = $null; paths = @(); probes = @(); captureFailure = $null }
    $comparisonFiles = @()
    $comparisonDirectory = $null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $evidence.identity = @{ name = $identity.Name; sid = $identity.User.Value; impersonationLevel = [string]$identity.ImpersonationLevel; administrator = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); groups = @($identity.Groups | ForEach-Object Value) }
        } finally { $identity.Dispose() }
        # Allowlist: never dump the runner's credentials or entire environment.
        foreach ($name in @('PATH', 'PATHEXT', 'HOME', 'USERPROFILE', 'USERNAME', 'USERDOMAIN', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'COMSPEC', 'SystemRoot', '__COMPAT_LAYER')) {
            $evidence.environment[$name] = $script:GitEnvironment[$name]
        }
        $executables = @('cmd/git.exe', 'cmd/git-upload-pack.exe', 'ucrt64/bin/git.exe', 'ucrt64/bin/git-upload-pack.exe', 'ucrt64/bin/ash.exe', 'ucrt64/bin/busybox.exe') | ForEach-Object { Join-Path $Root $_ }
        # Same bytes in ASCII/Unicode sibling names isolate metadata decoding
        # from inherited directory permissions. Never execute either copy.
        $comparisonDirectory = Join-Path $script:RunRoot ('metadata-comparison-' + [Guid]::NewGuid().ToString('N'))
        Assert-Acceptance ($comparisonDirectory -notmatch '[^\x00-\x7f]') 'Metadata comparison requires an ASCII-only diagnostic directory.'
        [IO.Directory]::CreateDirectory($comparisonDirectory) | Out-Null
        $comparisonFiles = @((Join-Path $comparisonDirectory 'git-upload-pack.exe'), (Join-Path $comparisonDirectory 'git-upload-pack-中文.exe'))
        $comparisonSource = Join-Path $Root 'ucrt64/bin/git-upload-pack.exe'
        $comparisonHash = Get-Sha256 $comparisonSource
        foreach ($copy in $comparisonFiles) {
            [IO.File]::Copy($comparisonSource, $copy)
            Assert-Acceptance ((Get-Sha256 $copy) -ceq $comparisonHash) 'Metadata comparison copy differs from the installed executable.'
        }
        $evidence.metadataComparison = @{ source = $comparisonSource; sha256 = $comparisonHash; copies = $comparisonFiles; purpose = 'stat/test -x only; copies are never executed and are deleted after capture' }
        $executables += $comparisonFiles
        $paths = @($Root, (Join-Path $Root 'cmd'), (Join-Path $Root 'ucrt64/bin'), $script:RunRoot, $Source, (Join-Path $Source '.git')) + $executables
        # Record every ancestor without changing its ACL. A restricted account
        # may traverse a directory while being unable to enumerate/read its ACL.
        foreach ($leaf in @($Root, $script:RunRoot)) {
            $ancestor = [IO.Directory]::GetParent($leaf)
            while ($ancestor) {
                if ($ancestor.FullName -notin $paths) { $paths += $ancestor.FullName }
                $ancestor = $ancestor.Parent
            }
        }
        foreach ($path in $paths) {
            $entry = [ordered]@{ path = $path; exists = $false; attributes = $null; owner = $null; sddl = $null; sha256 = $null; embeddedManifestText = @(); error = $null }
            try {
                $item = Get-Item -LiteralPath $path -Force
                $entry.exists = $true
                $entry.attributes = [string]$item.Attributes
                $acl = Get-Acl -LiteralPath $path
                $entry.owner = $acl.Owner
                $entry.sddl = $acl.Sddl
                if ($path -in $executables) {
                    $entry.sha256 = Get-Sha256 $path
                    # Preserve actual embedded XML, not a guessed privilege level.
                    # This byte scan is evidence only, not a PE-resource validator;
                    # no match does not establish that a manifest is absent.
                    $bytes = [IO.File]::ReadAllBytes($path)
                    foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
                        $text = $encoding.GetString($bytes)
                        foreach ($match in [Regex]::Matches($text, '(?s)<assembly\b[^>]*>.*?</assembly>')) {
                            $entry.embeddedManifestText += @{ encoding = $encoding.WebName; xml = $match.Value }
                        }
                    }
                }
            } catch { $entry.error = $_.Exception.ToString() }
            $evidence.paths += $entry
        }
        # Alias execution uses the installed wrapper, Git's own PATH setup and
        # configured BusyBox, exactly as the transport does. whoami is an actual
        # Windows token query, not an environment-derived username.
        $contextAlias = 'alias.transport-context=!f() { printf "PATH=%s\nHOME=%s\nUSERPROFILE=%s\nUSERNAME=%s\nHOMEDRIVE=%s\nHOMEPATH=%s\nCOMSPEC=%s\n" "$PATH" "$HOME" "$USERPROFILE" "$USERNAME" "$HOMEDRIVE" "$HOMEPATH" "$COMSPEC"; command -v git-upload-pack || return; type git-upload-pack || return; whoami.exe /all; }; f'
        $shellProbe = 'alias.transport-probe=!f() { exec "$@"; }; f'
        # Read the native child's UTF-16 environment, not another BusyBox
        # applet's UTF-8 view. EncodedCommand avoids a second shell quoting
        # layer; Console.WriteLine emits UTF-8 into the existing command log.
        # Only the isolated PATH and this probe's Git-generated config are
        # exposed. Never enumerate the child's whole environment.
        $nativePowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $nativeEnvironmentCommand = '$env:PSModulePath = [IO.Path]::Combine($PSHOME, "Modules"); [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); foreach ($name in @("PATH", "GIT_CONFIG_PARAMETERS")) { [Console]::WriteLine((ConvertTo-Json -Compress -InputObject @{ name = $name; value = [Environment]::GetEnvironmentVariable($name) })) }'
        $nativeEnvironmentArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nativeEnvironmentCommand)))
        $nativeEnvironmentAlias = 'alias.transport-native-env=!f() { printf "shell.PATH=%s\nshell.GIT_CONFIG_PARAMETERS=%s\n" "$PATH" "$GIT_CONFIG_PARAMETERS"; exec "$@"; }; f'
        # Compare exec with a normal child: ash uses a forkshell for the latter.
        $nativeChildEnvironmentAlias = 'alias.transport-native-child-env=!f() { printf "shell.PATH=%s\nshell.GIT_CONFIG_PARAMETERS=%s\n" "$PATH" "$GIT_CONFIG_PARAMETERS"; "$@"; status=$?; return "$status"; }; f'
        $probes = @(
            @{ name = 'git-shell-context-and-token'; file = $script:Git; arguments = @('-c', $contextAlias, 'transport-context') },
            @{ name = 'parent-token'; file = (Join-Path $env:SystemRoot 'System32/whoami.exe'); arguments = @('/all') },
            @{ name = 'busybox-identity'; file = (Join-Path $Root 'ucrt64/bin/busybox.exe'); arguments = @('id') },
            @{ name = 'busybox-file-modes'; file = (Join-Path $Root 'ucrt64/bin/busybox.exe'); arguments = @('stat', '-c', '%a %u %g %n', '--') + $paths },
            @{ name = 'shell-token'; file = $script:Git; arguments = @('-c', $shellProbe, 'transport-probe', (Join-Path $env:SystemRoot 'System32/whoami.exe').Replace('\', '/'), '/all') },
            @{ name = 'shell-path-candidates'; file = $script:Git; arguments = @('-c', $shellProbe, 'transport-probe', (Join-Path $env:SystemRoot 'System32/where.exe').Replace('\', '/'), 'git-upload-pack') },
            @{ name = 'direct-native-environment'; file = $nativePowerShell; arguments = $nativeEnvironmentArguments },
            @{ name = 'shell-exec-native-environment'; file = $script:Git; arguments = @('-c', $nativeEnvironmentAlias, 'transport-native-env', $nativePowerShell.Replace('\', '/')) + $nativeEnvironmentArguments },
            @{ name = 'shell-child-native-environment'; file = $script:Git; arguments = @('-c', $nativeChildEnvironmentAlias, 'transport-native-child-env', $nativePowerShell.Replace('\', '/')) + $nativeEnvironmentArguments },
            @{ name = 'git-builtin-upload-pack'; file = $script:Git; arguments = @('upload-pack', '--advertise-refs', $Source) },
            @{ name = 'shell-path-upload-pack'; file = $script:Git; arguments = @('-c', $shellProbe, 'transport-probe', 'git-upload-pack', '--advertise-refs', $Source) }
        )
        foreach ($copy in $comparisonFiles) {
            $probes += @{ name = "shell-metadata-comparison-$([IO.Path]::GetFileName($copy))"; file = $script:Git; arguments = @('-c', 'alias.transport-executable=!f() { test -x "$1"; }; f', 'transport-executable', $copy.Replace('\', '/')) }
        }
        foreach ($relative in @('cmd/git-upload-pack.exe', 'ucrt64/bin/git-upload-pack.exe')) {
            $program = Join-Path $Root $relative
            $probes += @{ name = "shell-executable-test-$relative"; file = $script:Git; arguments = @('-c', 'alias.transport-executable=!f() { test -x "$1"; }; f', 'transport-executable', $program.Replace('\', '/')) }
            $probes += @{ name = "direct-$relative"; file = $program; arguments = @('--advertise-refs', $Source) }
            $probes += @{ name = "shell-absolute-$relative"; file = $script:Git; arguments = @('-c', $shellProbe, 'transport-probe', $program.Replace('\', '/'), '--advertise-refs', $Source) }
        }
        foreach ($probe in $probes) {
            $result = [ordered]@{ name = $probe.name; file = $probe.file; arguments = $probe.arguments; commandId = $null; exit = $null; exception = $null; nativeErrorCode = $null }
            try {
                # Collect every result even on failure, then rethrow the original
                # clone error at the caller. No failed probe can make CI pass.
                $command = Invoke-AcceptanceProcess -File $probe.file -Arguments $probe.arguments -Directory $script:RunRoot -Environment $script:GitEnvironment -ExpectedExit @() -TimeoutSeconds 30
                $result.commandId = $command.id
                $result.exit = $command.exit
            } catch {
                $result.exception = $_.Exception.ToString()
                $exception = $_.Exception
                while ($exception) {
                    if ($exception -is [ComponentModel.Win32Exception]) { $result.nativeErrorCode = $exception.NativeErrorCode; break }
                    $exception = $exception.InnerException
                }
            }
            $evidence.probes += $result
        }
    } catch {
        $evidence.captureFailure = $_.Exception.ToString()
        throw
    } finally {
        try {
            foreach ($copy in $comparisonFiles) { [IO.File]::Delete($copy) }
            if ($comparisonDirectory -and [IO.Directory]::Exists($comparisonDirectory)) { [IO.Directory]::Delete($comparisonDirectory) }
        } finally {
            Write-Utf8 $evidencePath ($evidence | ConvertTo-Json -Depth 10)
        }
    }
}
