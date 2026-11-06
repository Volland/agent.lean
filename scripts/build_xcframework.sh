#!/usr/bin/env bash
# Build agent.lean's source bundle for Apple platforms and package it as AgentLeanC.xcframework.
#
#   scripts/build_xcframework.sh                 # all slices
#   SLICES="macos ios" scripts/build_xcframework.sh
#
# Slices (static libAgentLeanC.a each, C++20 Lean runtime inside, needs libc++ at link time):
#   macos          macOS            ($MACOS_ARCHS, default "arm64;x86_64")
#   ios            iOS device       arm64
#   ios-simulator  iOS simulator    ($SIM_ARCHS, default "arm64;x86_64")
#   maccatalyst    Mac Catalyst     ($CATALYST_ARCHS, default "arm64 x86_64", one build per arch + lipo)
#
# x86_64 is included so Xcode's generic "Any Mac" / simulator builds link; drop it with
# MACOS_ARCHS=arm64 SIM_ARCHS=arm64 CATALYST_ARCHS=arm64 for a faster arm64-only build.
#
# Input:  bundle/out (generate it with scripts/bundle.py), or $AGENTLEAN_BUNDLE.
# Output: bindings/swift/AgentLeanC.xcframework, or $AGENTLEAN_XCF_OUT. The headers of every slice
#         are agent.h plus a module map that exposes it as the Clang module `AgentLeanC`.
# Build directories go under build/xcframework/<slice> (gitignored) and are reused incrementally.
#
# Environment knobs: SLICES, MACOS_ARCHS, SIM_ARCHS, CATALYST_ARCHS, IOS_MIN (15.0), MACOS_MIN (13.0),
# CATALYST_MIN (16.0), JOBS, AGENTLEAN_OPT_SIZE (ON for -Os), CLEAN=1 (wipe build dirs first).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${AGENTLEAN_BUNDLE:-$ROOT/bundle/out}"
BUILD="${AGENTLEAN_XCF_BUILD:-$ROOT/build/xcframework}"
OUT="${AGENTLEAN_XCF_OUT:-$ROOT/bindings/swift/AgentLeanC.xcframework}"
SLICES="${SLICES:-macos ios ios-simulator maccatalyst}"
MACOS_ARCHS="${MACOS_ARCHS:-arm64;x86_64}"
SIM_ARCHS="${SIM_ARCHS:-arm64;x86_64}"
CATALYST_ARCHS="${CATALYST_ARCHS:-arm64 x86_64}"
IOS_MIN="${IOS_MIN:-15.0}"
MACOS_MIN="${MACOS_MIN:-13.0}"
CATALYST_MIN="${CATALYST_MIN:-16.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
OPT_SIZE="${AGENTLEAN_OPT_SIZE:-OFF}"
CMAKE="${CMAKE:-$(command -v cmake || echo /opt/homebrew/bin/cmake)}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$BUNDLE/CMakeLists.txt" ] || die "no source bundle at $BUNDLE (run scripts/bundle.py first)"
[ -f "$BUNDLE/extra/agent.h" ] || die "$BUNDLE/extra/agent.h is missing"
[ -x "$CMAKE" ] || die "cmake not found"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"

# Configure and build only the library target of the bundle for one slice.
build_slice() {
  local slice="$1"; shift
  local dir="$BUILD/$slice"
  [ "${CLEAN:-0}" = 1 ] && rm -rf "$dir"
  log "configure $slice"
  "$CMAKE" -S "$BUNDLE" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DAGENTLEAN_OPT_SIZE="$OPT_SIZE" "$@" >"$dir.configure.log" 2>&1 \
    || { tail -40 "$dir.configure.log" >&2; die "configure failed for $slice (log: $dir.configure.log)"; }
  log "build $slice"
  "$CMAKE" --build "$dir" --target agentlean -j "$JOBS" >"$dir.build.log" 2>&1 \
    || { tail -40 "$dir.build.log" >&2; die "build failed for $slice (log: $dir.build.log)"; }
  [ -f "$dir/libagentlean.a" ] || die "$dir/libagentlean.a was not produced"
  log "$slice: $(lipo -info "$dir/libagentlean.a" 2>/dev/null | sed 's/.*: //')"
}

mkdir -p "$BUILD"
for slice in $SLICES; do
  case "$slice" in
    macos)
      build_slice macos -DCMAKE_OSX_SYSROOT=macosx \
        -DCMAKE_OSX_ARCHITECTURES="$MACOS_ARCHS" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" ;;
    ios)
      build_slice ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" ;;
    ios-simulator)
      build_slice ios-simulator -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_OSX_ARCHITECTURES="$SIM_ARCHS" -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" ;;
    maccatalyst)
      # Catalyst is the macOS SDK with the iOS-on-Mac ABI, selected by the target triple, which
      # carries the arch: build each arch on its own and merge them.
      libs=()
      for arch in $CATALYST_ARCHS; do
        build_slice "maccatalyst-$arch" -DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_ARCHITECTURES="$arch" \
          -DCMAKE_OSX_DEPLOYMENT_TARGET= \
          -DCMAKE_C_FLAGS="-target $arch-apple-ios${CATALYST_MIN}-macabi" \
          -DCMAKE_CXX_FLAGS="-target $arch-apple-ios${CATALYST_MIN}-macabi"
        libs+=("$BUILD/maccatalyst-$arch/libagentlean.a")
      done
      mkdir -p "$BUILD/maccatalyst"
      lipo -create "${libs[@]}" -output "$BUILD/maccatalyst/libagentlean.a" ;;
    *) die "unknown slice '$slice' (macos ios ios-simulator maccatalyst)" ;;
  esac
done

# Headers shared by every slice: agent.h and a module map, so Swift can `import AgentLeanC`.
HEADERS="$BUILD/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$BUNDLE/extra/agent.h" "$HEADERS/agent.h"
cat >"$HEADERS/module.modulemap" <<'EOF'
module AgentLeanC {
  header "agent.h"
  link "c++"
  export *
}
EOF

# Each slice's library is staged as libAgentLeanC.a: on a case-insensitive file system
# libagentlean.a would collide with the libAgentLean.a SwiftPM/Xcode build for the Swift target.
args=()
for slice in $SLICES; do
  mkdir -p "$BUILD/stage/$slice"
  cp "$BUILD/$slice/libagentlean.a" "$BUILD/stage/$slice/libAgentLeanC.a"
  args+=(-library "$BUILD/stage/$slice/libAgentLeanC.a" -headers "$HEADERS")
done
log "package $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" >/dev/null
for d in "$OUT"/*/; do
  [ -f "$d/libAgentLeanC.a" ] && log "  $(basename "$d"): $(lipo -info "$d/libAgentLeanC.a" | sed 's/.*: //')"
done
log "done"
