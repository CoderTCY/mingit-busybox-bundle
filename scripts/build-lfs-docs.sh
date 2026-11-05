#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]] || { echo 'LFS generation is restricted to GitHub Actions' >&2; exit 1; }
[[ $# == 4 ]] || { echo 'usage: build-lfs-docs.sh <source> <work> <tag> <commit>' >&2; exit 2; }
source_root=$(cygpath -au "$1")
work=$(cygpath -au "$2")
tag=$3
commit=$4
# Reuse the same SDK Ruby/Asciidoctor as the official Git documentation recipe.
# No gem install, secondary Ruby, network fallback, or replacement renderer.
export PATH="/ucrt64/bin:/usr/bin:$PATH"
command -v asciidoctor
command -v ruby
{
    asciidoctor --version
    ruby --version
    msgfmt --version
    pacman -Q
} >"$work/documentation-toolchain.txt"
cd "$source_root"
make man VERSION="$tag" GIT_LFS_SHA="$commit" ASCIIDOCTOR="$(command -v asciidoctor)" ASCIIDOCTOR_EXTRA_ARGS='-a reproducible -a webfonts!'
[[ -s man/html/git-lfs.1.html && -s man/man1/git-lfs.1 ]]
