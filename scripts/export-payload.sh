#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $# == 4 ]] || { echo 'usage: export-payload.sh <project-root> <output-root> <package-version> <recipe-commit>' >&2; exit 2; }
project=$(cygpath -au "$1")
output=$(cygpath -au "$2")
version=$3
recipe_commit=$4
[[ $MSYSTEM == UCRT64 && $MINGW_PREFIX == /ucrt64 ]] || exit 1
export PATH=/ucrt64/bin:/usr/bin:/usr/bin/core_perl:$PATH
export GIT_CONFIG_PARAMETERS="'core.autocrlf=false' 'core.eol=lf'"
[[ $(git -C "$output/work/build-extra" rev-parse HEAD) == "${BUNDLE_BUILD_EXTRA_COMMIT:?}" ]] || { echo 'Exporter revision mismatch' >&2; exit 1; }
[[ $(git --version) == "git version ${BUNDLE_GIT_TAG#v}.busyboxbundle.${recipe_commit:0:12}" ]] || { echo 'SDK does not contain this custom Git' >&2; exit 1; }
export_dir="$output/work/export"
[[ ! -e $export_dir ]] || { echo "Exporter destination already exists: $export_dir" >&2; exit 1; }
mkdir -p "$export_dir"
bash "$output/work/build-extra/please.sh" make-installers-from-mingw-w64-git --only-mingit-busybox --version="$version" --output="$export_dir"
gcc "$project/native/mingit-open.c" -o "$output/work/mingit-open.exe" -municode -O2 -s -Wl,--dynamicbase,--nxcompat -lshell32 -lole32
pacman -Q >"$output/work/sdk-packages.txt"
