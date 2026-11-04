#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Produces the complete redistribution tree; build.ps1 archives it only on success.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: collect-sources.sh <payload-root> <output-dir>' >&2; exit 2; }
: "${BUNDLE_PWSH:?}" "${BUNDLE_PROJECT_ROOT:?}" "${BUNDLE_OUTPUT_ROOT:?}" "${BUNDLE_INPUTS_PATH:?}"
[[ ${MSYSTEM:-} == UCRT64 && ${MINGW_PREFIX:-} == /ucrt64 ]] || { echo 'UCRT64 SDK required' >&2; exit 1; }
pwsh=$(cygpath -au "$BUNDLE_PWSH")
project=$(cygpath -au "$BUNDLE_PROJECT_ROOT")
payload=$(cygpath -aw "$1")
destination=$(cygpath -aw "$2")
sdk=$(cygpath -aw /)
# PowerShell checks each native command; exec preserves its failure for the build.
exec "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$project/scripts/collect-sources.ps1" \
    -PayloadRoot "$payload" -OutputDirectory "$destination" -SdkRoot "$sdk" \
    -ProjectRoot "$BUNDLE_PROJECT_ROOT" -BuildRoot "$BUNDLE_OUTPUT_ROOT" -InputsPath "$BUNDLE_INPUTS_PATH"
