#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Uninstaller,
    [Parameter(Mandatory)][string] $LogPath
)
$ErrorActionPreference = 'Stop'

# Start-Process -Wait joins descendants on Windows. Inno deliberately terminates
# the registered executable before the temporary second phase finishes cleanup.
# Paths originate from the registered EXE and a generated .log file, respectively.
$process = Start-Process -FilePath $Uninstaller -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$LogPath`"" -WorkingDirectory $PWD.Path -Wait -PassThru
try {
    if ($null -eq $process.ExitCode) { throw 'The uninstaller process tree did not yield an exit code.' }
    exit $process.ExitCode
} finally {
    $process.Dispose()
}
