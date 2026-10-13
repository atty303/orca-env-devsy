#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?release version required}
output=${2:?absolute artifact directory required}
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
[[ "$output" == /* ]]
[[ "${RELEASE_VERSION:-$version}" == "$version" ]]
[[ "${RELEASE_ARTIFACT_DIR:-$output}" == "$output" ]]
work=$(mktemp -d)
cp version.mbt "$work/version.mbt"
trap 'cp "$work/version.mbt" version.mbt; rm -rf "$work"' EXIT
printf '///|\npub let version : String = "%s"\n' "$version" > version.mbt
export MOON_TOOLCHAIN_ROOT="$PWD/.tools/cross/moon"
export MOON_CC="$PWD/scripts/clang-cross.sh" MOON_AR="$PWD/scripts/llvm-ar"
mkdir -p "$output"
for platform in macos-arm64 linux-x64 linux-arm64; do
  case "$platform" in
    macos-arm64) export ORCA_ENV_DEVSY_TARGET=aarch64-macos.13.0 ;;
    linux-x64) export ORCA_ENV_DEVSY_TARGET=x86_64-linux-gnu.2.31 ;;
    linux-arm64) export ORCA_ENV_DEVSY_TARGET=aarch64-linux-gnu.2.31 ;;
  esac
  build="$work/build/$platform"
  moon build --target native --release --deny-warn --target-dir "$build"
  package="$work/$platform"
  mkdir -p "$package/licenses"
  cp "$build/native/release/build/cmd/main/main.exe" "$package/orca-env-devsy"
  cp LICENSE "$package/LICENSE"
  cp .mooncakes/moonbitlang/async/LICENSE "$package/licenses/moonbitlang-async.txt"
  cp .mooncakes/moonbit-community/yaml/LICENSE "$package/licenses/moonbit-community-yaml.txt"
  cp "$MOON_TOOLCHAIN_ROOT/lib/core/LICENSE" "$package/licenses/moonbitlang-core.txt"
  if [[ "$platform" == macos-arm64 ]]; then
    cp "$MOON_TOOLCHAIN_ROOT/cross-headers/sys/vnode.h" "$package/licenses/apple-xnu-vnode.h.txt"
  fi
  size=$(wc -c < "$package/orca-env-devsy")
  printf 'Standalone executable: %s bytes (%s)\n' "$size" "$platform"
  tar -czf "$output/orca-env-devsy-$version-$platform.tar.gz" -C "$package" orca-env-devsy LICENSE licenses
done
