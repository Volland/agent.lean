#!/usr/bin/env bash
# Build the Android AAR of the Kotlin binding without Gradle:
#   1. libagentlean_jni.so for each ABI with the NDK (bundle/out compiled in, libc++ static),
#   2. the Kotlin sources (bindings/kotlin/src/main/kotlin) to classes.jar with kotlinc,
#   3. build/android/agentlean.aar assembled by hand (zip), then verified.
#
#   scripts/build_android.sh                     # arm64-v8a and x86_64
#   ABIS="arm64-v8a" scripts/build_android.sh    # a subset
#
# Env: ANDROID_HOME (default ~/Library/Android/sdk), ANDROID_NDK (default $ANDROID_HOME/ndk/27.0.11718014,
# else the newest installed), ANDROID_PLATFORM (default android-24).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KT="$ROOT/bindings/kotlin"
OUT="$ROOT/build/android"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK:-$ANDROID_HOME/ndk/27.0.11718014}"
if [ ! -d "$NDK" ]; then NDK="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"; fi
[ -f "$NDK/build/cmake/android.toolchain.cmake" ] || { echo "no Android NDK found (set ANDROID_NDK)" >&2; exit 1; }
PLATFORM="${ANDROID_PLATFORM:-android-24}"
MIN_SDK="${PLATFORM#android-}"
ABIS="${ABIS:-arm64-v8a x86_64}"
LLVM="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -1)/bin"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "NDK: $NDK  platform: $PLATFORM  ABIs: $ABIS"

STAGE="$OUT/aar"
rm -rf "$STAGE" "$OUT/agentlean.aar"
mkdir -p "$STAGE/jni"

# 1. Native libraries.
for abi in $ABIS; do
  echo "== libagentlean_jni.so for $abi"
  cmake -S "$KT" -B "$OUT/jni-$abi" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM="$PLATFORM" -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release -DAGENTLEAN_BUNDLE_DIR="$ROOT/bundle/out" >/dev/null
  cmake --build "$OUT/jni-$abi" --target agentlean_jni -j "$JOBS"
  mkdir -p "$STAGE/jni/$abi"
  # The build keeps debug info; ship a stripped copy.
  "$LLVM/llvm-strip" --strip-unneeded -o "$STAGE/jni/$abi/libagentlean_jni.so" "$OUT/jni-$abi/libagentlean_jni.so"
done

# 2. classes.jar. The sources use no Android API, so android.jar is not needed on the classpath.
# Java 8 bytecode: D8 desugars it for every minSdk. The app supplies kotlin-stdlib.
echo "== classes.jar"
rm -rf "$OUT/classes"
mkdir -p "$OUT/classes"
kotlinc -nowarn -no-reflect -jvm-target 1.8 -module-name agentlean \
  -d "$OUT/classes" "$KT"/src/main/kotlin/dev/agentlean/*.kt
(cd "$OUT/classes" && jar cf "$STAGE/classes.jar" .)

# 3. AAR.
cat > "$STAGE/AndroidManifest.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.agentlean">
    <uses-sdk android:minSdkVersion="$MIN_SDK" />
</manifest>
XML
cat > "$STAGE/proguard.txt" <<'PRO'
# agent.lean JNI: native methods are bound by name and the glue constructs AgentException(byte[]).
-keep class dev.agentlean.AgentNative { native <methods>; }
-keep class dev.agentlean.AgentException { <init>(byte[]); }
PRO
: > "$STAGE/R.txt"
(cd "$STAGE" && zip -q -r -X "$OUT/agentlean.aar" AndroidManifest.xml classes.jar proguard.txt R.txt jni)

# Verify.
echo "== verify"
fail=0
for abi in $ABIS; do
  so="$STAGE/jni/$abi/libagentlean_jni.so"
  desc="$(file -b "$so")"
  echo "$abi: $desc"
  case "$abi" in
    arm64-v8a) want="ARM aarch64" ;;
    x86_64) want="x86-64" ;;
    armeabi-v7a) want="ARM, EABI5" ;;
    x86) want="Intel 80386" ;;
  esac
  case "$desc" in *ELF*"$want"*) ;; *) echo "  wrong architecture for $abi" >&2; fail=1 ;; esac
  needed="$("$LLVM/llvm-readelf" -d "$so" | awk '/NEEDED/ {print $NF}' | tr -d '[]' | tr '\n' ' ')"
  echo "  NEEDED: $needed"
  case "$needed" in *c++_shared*) echo "  links libc++_shared.so (expected static libc++)" >&2; fail=1 ;; esac
  exported="$("$LLVM/llvm-nm" -D --defined-only "$so" | awk '{print $NF}' | grep -c '^Java_dev_agentlean_' || true)"
  others="$("$LLVM/llvm-nm" -D --defined-only "$so" | awk '{print $NF}' | { grep -v '^Java_dev_agentlean_' || true; } | tr '\n' ' ')"
  echo "  exported JNI functions: $exported; other exports: ${others:-none}"
  [ "$exported" -ge 13 ] || { echo "  missing JNI exports" >&2; fail=1; }
  align="$("$LLVM/llvm-readelf" -lW "$so" | awk '$1=="LOAD" {print $NF}' | sort -u | tr '\n' ' ')"
  echo "  LOAD alignment: $align"
done
echo "== $OUT/agentlean.aar"
unzip -l "$OUT/agentlean.aar"
for f in AndroidManifest.xml classes.jar $(for abi in $ABIS; do echo "jni/$abi/libagentlean_jni.so"; done); do
  unzip -l "$OUT/agentlean.aar" "$f" >/dev/null || { echo "AAR is missing $f" >&2; fail=1; }
done
unzip -p "$OUT/agentlean.aar" classes.jar > "$OUT/classes-check.jar"
unzip -l "$OUT/classes-check.jar" | grep -q 'dev/agentlean/Agent.class' || { echo "classes.jar lacks dev/agentlean/Agent.class" >&2; fail=1; }
rm -f "$OUT/classes-check.jar"
[ "$fail" = 0 ] && echo "OK: $OUT/agentlean.aar" || { echo "verification failed" >&2; exit 1; }
