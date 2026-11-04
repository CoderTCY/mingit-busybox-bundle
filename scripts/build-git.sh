#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
[[ $# == 5 ]] || { echo 'usage: build-git.sh <git-tag> <git-commit> <recipe-commit> <project-root> <output-root>' >&2; exit 2; }
export BUNDLE_GIT_TAG=$1 BUNDLE_GIT_COMMIT=$2 BUNDLE_RECIPE_COMMIT=$3
project=$(cygpath -au "$4")
output=$(cygpath -au "$5")
[[ $MSYSTEM == UCRT64 && $MINGW_PREFIX == /ucrt64 ]] || { echo 'UCRT64 SDK required' >&2; exit 1; }
[[ $project != *' '* && $output != *' '* ]] || { echo 'SDK build paths must not contain spaces' >&2; exit 1; }
[[ $BUNDLE_GIT_COMMIT =~ ^[0-9a-f]{40}$ && $BUNDLE_RECIPE_COMMIT =~ ^[0-9a-f]{40}$ ]] || exit 2
: "${BUNDLE_MINGW_PACKAGES_COMMIT:?}" "${BUNDLE_BUILD_EXTRA_COMMIT:?}"
[[ $(git -C "$project" rev-parse HEAD) == "$BUNDLE_RECIPE_COMMIT" ]] || { echo 'Recipe identity mismatch' >&2; exit 1; }
export PATH=/ucrt64/bin:/usr/bin:/usr/bin/core_perl:$PATH
# Do not let a developer's global autoCRLF change archive/checksum bytes.
export GIT_CONFIG_PARAMETERS="'core.autocrlf=false' 'core.eol=lf' 'core.longpaths=true'"
BUNDLE_CORE_PATCH_SHA256=$(sha256sum "$project/patches/0001-core-shell.patch" | cut -d' ' -f1)
export BUNDLE_CORE_PATCH_SHA256
export PKGEXT=.pkg.tar.zst SRCEXT=.src.tar.gz
export MINGW_ARCH=ucrt64
MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS
mkdir -p "$output/work" "$output/test-results" "$output/work/packages" "$output/work/sources"

checkout_pinned() {
    local name=$1 sha=$2 destination=$3
    if [[ ! -d $destination/.git ]]; then
        git init "$destination"
        git -C "$destination" fetch --depth=1 "https://github.com/git-for-windows/$name.git" "$sha"
        git -C "$destination" -c core.autocrlf=false checkout --detach FETCH_HEAD
    fi
    [[ $(git -C "$destination" rev-parse HEAD) == "$sha" ]] || { echo "Wrong checkout: $destination" >&2; exit 1; }
}
checkout_pinned MINGW-packages "$BUNDLE_MINGW_PACKAGES_COMMIT" "$output/work/MINGW-packages"
checkout_pinned build-extra "$BUNDLE_BUILD_EXTRA_COMMIT" "$output/work/build-extra"
recipe="$output/work/package-recipe"
[[ ! -e $recipe ]] || { echo "Build recipe already exists: $recipe; use a fresh output root" >&2; exit 1; }
mkdir -p "$recipe"
git init "$recipe/adaptation"
git -C "$output/work/MINGW-packages" archive "$BUNDLE_MINGW_PACKAGES_COMMIT" mingw-w64-git | tar -x -C "$recipe" --strip-components=1
# Apply to the pinned repository layout without changing the cached checkout.
mkdir -p "$recipe/adaptation/mingw-w64-git"
cp "$recipe/PKGBUILD" "$recipe/adaptation/mingw-w64-git/PKGBUILD"
git -C "$recipe/adaptation" apply --check "$project/patches/0002-package-inputs.patch"
git -C "$recipe/adaptation" apply "$project/patches/0002-package-inputs.patch"
cp "$recipe/adaptation/mingw-w64-git/PKGBUILD" "$recipe/PKGBUILD"
cp "$project/patches/0001-core-shell.patch" "$recipe/0001-core-shell.patch"

# A shallow, commit-only cache avoids fetching unrelated branches while retaining
# a real VCS source for makepkg --allsource. The original HTTPS origin is retained.
git init --bare "$recipe/git"
git -C "$recipe/git" remote add origin https://github.com/git-for-windows/git.git
git -C "$recipe/git" config remote.origin.fetch "+$BUNDLE_GIT_COMMIT:refs/heads/bundle-source"
git -C "$recipe/git" fetch --depth=1 origin "$BUNDLE_GIT_COMMIT:refs/heads/bundle-source"
git -C "$recipe/git" symbolic-ref HEAD refs/heads/bundle-source
[[ $(git -C "$recipe/git" rev-parse HEAD) == "$BUNDLE_GIT_COMMIT" ]] || exit 1

pacman -Sy --noconfirm
# The SDK subset retains package metadata but trims these binaries. Reinstall
# their official packages, rather than bypassing makepkg's MSYS Git wrapper.
if [[ ! -x /usr/bin/git.exe || ! -x /usr/bin/pacman-conf.exe ]]; then
    pacman -S --noconfirm git pacman
fi
if [[ ! -f /usr/bin/msys-curl-4.dll ]]; then
    pacman -S --noconfirm libcurl
fi
if [[ ! -f /usr/bin/msys-nghttp2-14.dll || ! -f /usr/bin/msys-ssh2-1.dll ]]; then
    pacman -S --noconfirm libnghttp2 libssh2
fi
if [[ ! -f /ucrt64/bin/libsqlite3-0.dll ]]; then
    pacman -S --noconfirm mingw-w64-ucrt-x86_64-sqlite3
fi
if [[ ! -x /ucrt64/bin/x86_64-w64-mingw32-gcc.exe ]]; then
    pacman -S --noconfirm mingw-w64-ucrt-x86_64-gcc
fi
if [[ ! -f /ucrt64/lib/libdbghelp.a ]]; then
    pacman -S --noconfirm mingw-w64-ucrt-x86_64-crt
fi
pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-rust
cargo --version
rustc --version
x86_64-w64-mingw32-gcc --version
/usr/bin/git --version
cd "$recipe"
export PKGDEST="$output/work/packages" SRCPKGDEST="$output/work/sources"
MINGW_ARCH=ucrt64 makepkg-mingw --syncdeps --noconfirm --cleanbuild --force 2>&1 | tee "$output/test-results/build-git.log"
# Build and run the existing process-spawning regression with no core.shell override.
make -C "$recipe/src/git" test T=t0061-run-command.sh 2>&1 | tee "$output/test-results/t0061.log"
MINGW_ARCH=ucrt64 makepkg-mingw --allsource --noconfirm --force 2>&1 | tee "$output/test-results/allsource.log"

# Select packages by metadata, never glob-install stale products or extra splits.
package_list=$(MINGW_ARCH=ucrt64 makepkg-mingw --packagelist)
mapfile -t built <<<"$package_list"
selected=()
for wanted in mingw-w64-ucrt-x86_64-git mingw-w64-ucrt-x86_64-git-doc-html mingw-w64-ucrt-x86_64-git-for-windows-addons; do
    matches=()
    for package in "${built[@]}"; do
        [[ -f $package ]] || { echo "Missing built package $package" >&2; exit 1; }
        metadata=$(pacman -Qp "$package")
        read -r name version <<<"$metadata"
        [[ $name != "$wanted" ]] || matches+=("$package")
    done
    [[ ${#matches[@]} == 1 ]] || { echo "Expected one built $wanted" >&2; exit 1; }
    selected+=("${matches[0]}")
done
printf '%s\n' "${selected[@]}" >"$output/work/built-packages.txt"
pacman -U --noconfirm "${selected[@]}"
pacman -Q >"$output/work/sdk-packages.txt"
gcc --version >"$output/work/compiler.txt"
printf '%s\n' "$BUNDLE_GIT_COMMIT" >"$output/work/git-source-commit.txt"
for po in "$recipe"/src/git/po/*.po; do basename "$po" .po; done >"$output/work/source-locales.txt"
git --version
[[ $(git --version) == "git version ${BUNDLE_GIT_TAG#v}.busyboxbundle.${BUNDLE_RECIPE_COMMIT:0:12}" ]] || { echo 'Installed Git is not the custom build' >&2; exit 1; }
