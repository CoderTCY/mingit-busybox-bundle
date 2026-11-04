#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: build-busybox.sh <project-root> <output-root>' >&2; exit 2; }
project=$(cygpath -au "$1")
output=$(cygpath -au "$2")
[[ $MSYSTEM == UCRT64 && $MINGW_PREFIX == /ucrt64 ]] || { echo 'UCRT64 SDK required' >&2; exit 1; }
: "${BUNDLE_BUSYBOX_COMMIT:?}" "${BUNDLE_BUSYBOX_VERSION:?}" "${BUNDLE_RECIPE_COMMIT:?}" "${BUNDLE_MINGW_PACKAGES_COMMIT:?}"
[[ $BUNDLE_BUSYBOX_COMMIT =~ ^[0-9a-f]{40}$ && $BUNDLE_RECIPE_COMMIT =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ $BUNDLE_BUSYBOX_VERSION =~ ^1\.38\.0\.[0-9]+\.[0-9a-f]+$ ]] || { echo 'Unexpected BusyBox package version' >&2; exit 1; }
[[ $(git -C "$output/work/MINGW-packages" rev-parse HEAD) == "$BUNDLE_MINGW_PACKAGES_COMMIT" ]] || { echo 'Wrong MINGW-packages checkout' >&2; exit 1; }
recipe="$output/work/busybox-package-recipe"
[[ ! -e $recipe ]] || { echo "Build recipe already exists: $recipe; use a fresh output root" >&2; exit 1; }
mkdir -p "$recipe/adaptation/mingw-w64-busybox" "$output/work/packages" "$output/work/sources" "$output/test-results"
git -C "$output/work/MINGW-packages" archive "$BUNDLE_MINGW_PACKAGES_COMMIT" mingw-w64-busybox | tar -x -C "$recipe" --strip-components=1
git init "$recipe/adaptation"
cp "$recipe/PKGBUILD" "$recipe/adaptation/mingw-w64-busybox/PKGBUILD"
git -C "$recipe/adaptation" apply --check "$project/patches/0004-busybox-package-inputs.patch"
git -C "$recipe/adaptation" apply "$project/patches/0004-busybox-package-inputs.patch"
cp "$recipe/adaptation/mingw-w64-busybox/PKGBUILD" "$recipe/PKGBUILD"
cp "$project/patches/0003-busybox-unicode.patch" "$recipe/0003-busybox-unicode.patch"
BUNDLE_BUSYBOX_PATCH_SHA256=$(sha256sum "$recipe/0003-busybox-unicode.patch" | cut -d' ' -f1)
export BUNDLE_BUSYBOX_PATCH_SHA256

# Preserve the canonical HTTPS origin and an actual VCS source in --allsource,
# without downloading unrelated branches or requiring history to derive versions.
git init --bare "$recipe/busybox-w32"
git -C "$recipe/busybox-w32" remote add origin https://github.com/git-for-windows/busybox-w32.git
git -C "$recipe/busybox-w32" config remote.origin.fetch "+$BUNDLE_BUSYBOX_COMMIT:refs/heads/bundle-source"
git -C "$recipe/busybox-w32" fetch --depth=1 origin "$BUNDLE_BUSYBOX_COMMIT:refs/heads/bundle-source"
git -C "$recipe/busybox-w32" symbolic-ref HEAD refs/heads/bundle-source
[[ $(git -C "$recipe/busybox-w32" rev-parse HEAD) == "$BUNDLE_BUSYBOX_COMMIT" ]] || { echo 'BusyBox source cache identity mismatch' >&2; exit 1; }

cd "$recipe"
export MINGW_ARCH=ucrt64 PKGEXT=.pkg.tar.zst SRCEXT=.src.tar.gz
export SRCDEST="$recipe" PKGDEST="$output/work/packages" SRCPKGDEST="$output/work/sources"
MINGW_ARCH=ucrt64 makepkg-mingw --syncdeps --noconfirm --cleanbuild --force 2>&1 | tee "$output/test-results/build-busybox.log"
[[ $(git -C "$recipe/src/busybox-w32" rev-parse HEAD) == "$BUNDLE_BUSYBOX_COMMIT" ]] || { echo 'Built BusyBox source identity mismatch' >&2; exit 1; }
MINGW_ARCH=ucrt64 makepkg-mingw --allsource --noconfirm --force 2>&1 | tee "$output/test-results/allsource-busybox.log"

# Neither a stale SDK package nor a different architecture/version can satisfy
# this selection. Only makepkg's exact output list is considered for installation.
expected_version="${BUNDLE_BUSYBOX_VERSION}.busyboxbundle.${BUNDLE_RECIPE_COMMIT:0:12}-1"
expected_name=mingw-w64-ucrt-x86_64-busybox
package_list=$(MINGW_ARCH=ucrt64 makepkg-mingw --packagelist)
mapfile -t built <<<"$package_list"
[[ ${#built[@]} == 1 && -f ${built[0]} ]] || { echo 'Expected exactly one built BusyBox package' >&2; exit 1; }
metadata=$(pacman -Qp "${built[0]}")
[[ $metadata == "$expected_name $expected_version" ]] || { echo "Unexpected BusyBox package metadata: $metadata" >&2; exit 1; }
source_archive="$SRCPKGDEST/mingw-w64-busybox-${expected_version}.src.tar.gz"
[[ -f $source_archive ]] || { echo "Missing BusyBox corresponding source: $source_archive" >&2; exit 1; }
printf '%s\n' "${built[@]}" >"$output/work/busybox-packages.txt"
printf '%s\n' "$BUNDLE_BUSYBOX_COMMIT" >"$output/work/busybox-source-commit.txt"
pacman -U --noconfirm "${built[@]}"
[[ $(pacman -Q "$expected_name") == "$expected_name $expected_version" ]] || { echo 'Installed BusyBox is not the custom package' >&2; exit 1; }
