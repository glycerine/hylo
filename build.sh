#!/usr/bin/env bash
set -euo pipefail

# jea note: this is not an official build script. It is simply
# what I had to do to actually get hylo to build.
#
# also supplies the .pc needed to find the specific llvm that hylo needs to test the hc compiler:
# ./build.sh test
# ./build.sh test --list-tests
# ./build.sh test --filter ParserTests
# HYLO_TEST_DISABLE_AVAILABILITY_CHECKING=0 ./build.sh test 

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT"

SWIFT_TOOLCHAIN="${SWIFT_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain}"
SWIFT_BIN="$SWIFT_TOOLCHAIN/usr/bin"

LLVM_NAME="llvm-20.1.6-x86_64-apple-darwin24.1.0-MinSizeRel"
LLVM_URL="https://github.com/hylo-lang/llvm-build/releases/download/20260522-192015/$LLVM_NAME.tar.zst"
LLVM_SHA256="92e10c933d8f36762b6deecacd20c315d73b618ebda480230ae83f1a1b042926"
LLVM_ROOT="${LLVM_ROOT:-$ROOT/.build/llvm/$LLVM_NAME}"
LLVM_PC="$LLVM_ROOT/pkgconfig/llvm.pc"
LLVM_ARCHIVE="$ROOT/.build/downloads/$LLVM_NAME.tar.zst"

if [[ ! -x "$SWIFT_BIN/swift" ]]; then
  echo "Swift toolchain not found at: $SWIFT_TOOLCHAIN" >&2
  echo "Install Swift 6.3.2 or set SWIFT_TOOLCHAIN=/path/to/*.xctoolchain" >&2
  exit 1
fi

if [[ ! -f "$LLVM_PC" ]]; then
  mkdir -p "$ROOT/.build/downloads" "$ROOT/.build/llvm"

  if [[ ! -f "$LLVM_ARCHIVE" ]]; then
    echo "Downloading Hylo LLVM bundle..."
    curl -L --fail -o "$LLVM_ARCHIVE" "$LLVM_URL"
  fi

  actual_sha="$(shasum -a 256 "$LLVM_ARCHIVE" | awk '{print $1}')"
  if [[ "$actual_sha" != "$LLVM_SHA256" ]]; then
    echo "Checksum mismatch for $LLVM_ARCHIVE" >&2
    echo "expected: $LLVM_SHA256" >&2
    echo "actual:   $actual_sha" >&2
    exit 1
  fi

  echo "Extracting Hylo LLVM bundle..."
  tar -xf "$LLVM_ARCHIVE" -C "$ROOT/.build/llvm"
fi

MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
cache_id="${HYLO_BUILD_CACHE_ID:-$(basename "$SWIFT_TOOLCHAIN")-macos$MACOSX_DEPLOYMENT_TARGET}"
CLANG_MODULE_CACHE="$ROOT/.build/build-script-cache/clang-module-cache/$cache_id"

mkdir -p \
  "$CLANG_MODULE_CACHE" \
  "$ROOT/.build/xdg-cache" \
  "$ROOT/.build/swiftpm-cache" \
  "$ROOT/.build/swiftpm-config" \
  "$ROOT/.build/swiftpm-security"

export PATH="$SWIFT_BIN:/usr/local/bin:/opt/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET
export PKG_CONFIG_PATH="$LLVM_ROOT/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE"
export SWIFT_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE"
export XDG_CACHE_HOME="$ROOT/.build/xdg-cache"
export DYLD_LIBRARY_PATH="$SWIFT_TOOLCHAIN/usr/lib/swift/macosx${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# This machine has a global Git rewrite from https://github.com/ to git@github.com.
# Hylo's dependencies are public, so use HTTPS for this build unless explicitly disabled.
if [[ "${BYPASS_GLOBAL_GIT_CONFIG:-1}" == "1" ]]; then
  export GIT_CONFIG_GLOBAL=/dev/null
fi

command="build"
if [[ $# -gt 0 ]]; then
  case "$1" in
    build | test)
      command="$1"
      shift
      ;;
  esac
fi

has_configuration=0
has_product=0
has_parallel_setting=0
is_listing_tests=0

for arg in "$@"; do
  case "$arg" in
    -c | --configuration | --configuration=*) has_configuration=1 ;;
    --product | --product=*) has_product=1 ;;
    --parallel | --no-parallel) has_parallel_setting=1 ;;
    -l | --list-tests | list) is_listing_tests=1 ;;
  esac
done

case "$command" in
  build)
    if [[ "$has_product" == "0" ]]; then
      set -- --product hc "$@"
    fi
    if [[ "$has_configuration" == "0" ]]; then
      set -- -c release "$@"
    fi
    ;;
  test)
    if [[ "$has_parallel_setting" == "0" && "$is_listing_tests" == "0" ]]; then
      set -- --parallel "$@"
    fi
    if [[ "$has_configuration" == "0" ]]; then
      set -- -c release "$@"
    fi
    ;;
esac

# Tests compile the Interpreter target, which uses Swift's UInt128. In Swift 6.3 that type is
# annotated as macOS 15+, but on this Sonoma machine it is provided by the selected toolchain
# runtime. Disable availability checking for local tests unless explicitly opted out.
if [[ "$command" == "test" && "${HYLO_TEST_DISABLE_AVAILABILITY_CHECKING:-1}" == "1" ]]; then
  set -- -Xswiftc -Xfrontend -Xswiftc -disable-availability-checking "$@"
fi

echo "Using Swift: $("$SWIFT_BIN/swift" --version | head -n 1)"
echo "Using LLVM:  $(PKG_CONFIG_PATH="$LLVM_ROOT/pkgconfig" pkg-config --modversion llvm)"

swiftpm_options=(
  --disable-sandbox \
  --disable-dependency-cache \
  --manifest-cache local \
  --cache-path "$ROOT/.build/swiftpm-cache" \
  --config-path "$ROOT/.build/swiftpm-config" \
  --security-path "$ROOT/.build/swiftpm-security" \
  --pkg-config-path "$LLVM_ROOT/pkgconfig" \
  --force-resolved-versions
)

swift "$command" \
  "$@" \
  "${swiftpm_options[@]}"

echo
case "$command" in
  build)
    echo "Build complete."
    echo "Run hc with:"
    echo "  DYLD_LIBRARY_PATH=\"$SWIFT_TOOLCHAIN/usr/lib/swift/macosx\${DYLD_LIBRARY_PATH:+:\$DYLD_LIBRARY_PATH}\" $ROOT/.build/release/hc --version"
    ;;
  test)
    echo "Tests complete."
    ;;
esac
