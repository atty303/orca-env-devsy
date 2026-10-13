#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source=$(mise where http:moonbit)
home="$PWD/.tools/cross/moon"
marker="$home/.prepared"
stamp="$source:$(zig version)"
[[ -f "$marker" && $(cat "$marker") == "$stamp" ]] && exit 0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL https://raw.githubusercontent.com/apple-oss-distributions/xnu/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/vnode.h -o "$work/vnode.h"
actual=$(shasum -a 256 "$work/vnode.h")
[[ "${actual%% *}" == 2d6b4a7f2963d78829f9f8b840568a433a4ae30a1fe8a99f18ecb314d430ecb2 ]]
mkdir -p "$PWD/.tools/cross"
rm -rf "$home"
# Use the source runtime without host-specific acceleration objects.
mkdir -p "$home/lib"
ln -s "$source/bin" "$home/bin"
ln -s "$source/include" "$home/include"
ln -s "$source/lib/core" "$home/lib/core"
cp -R "$source/lib/runtime" "$home/lib/runtime"
mkdir -p "$home/cross-headers/sys"
cp "$work/vnode.h" "$home/cross-headers/sys/vnode.h"
printf '%s\n' "$stamp" > "$marker"
