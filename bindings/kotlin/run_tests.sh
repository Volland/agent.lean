#!/usr/bin/env bash
# Build the JNI library for the host, compile the Kotlin binding and its conformance test with
# kotlinc, and replay every traces/*.golden on the desktop JVM. No Gradle needed.
#
#   bindings/kotlin/run_tests.sh            # link the prebuilt build/host/libagentlean.a if present
#   AGENTLEAN_FROM_SOURCE=1 bindings/kotlin/run_tests.sh   # compile bundle/out instead (~1-2 min)
#   AGENTLEAN_SERIAL=1 bindings/kotlin/run_tests.sh        # one process-wide lock (-Dagentlean.parallel=false)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/build/kotlin-host"
mkdir -p "$OUT"

# A JDK with jni.h: $JAVA_HOME, else Homebrew's openjdk.
JDK="${JAVA_HOME:-}"
if [ -z "$JDK" ] || [ ! -f "$JDK/include/jni.h" ]; then
  JDK="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
if [ -z "$JDK" ] || [ ! -f "$JDK/include/jni.h" ]; then
  JDK=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
fi
JAVA="$JDK/bin/java"
echo "JDK: $JDK"

PREBUILT=""
if [ -z "${AGENTLEAN_FROM_SOURCE:-}" ] && [ -f "$ROOT/build/host/libagentlean.a" ]; then
  PREBUILT="$ROOT/build/host/libagentlean.a"
  echo "linking prebuilt $PREBUILT"
else
  echo "compiling the bundle from $ROOT/bundle/out"
fi

cmake -S "$HERE" -B "$OUT/jni" -DCMAKE_BUILD_TYPE=Release \
  -DAGENTLEAN_BUNDLE_DIR="$ROOT/bundle/out" \
  -DAGENTLEAN_PREBUILT_LIB="$PREBUILT" \
  -DAGENTLEAN_JNI_INCLUDE="$JDK/include" >/dev/null
cmake --build "$OUT/jni" --target agentlean_jni -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

LIB=""
for f in "$OUT/jni/libagentlean_jni.dylib" "$OUT/jni/libagentlean_jni.so"; do [ -f "$f" ] && LIB="$f" && break; done
[ -n "$LIB" ] || { echo "libagentlean_jni was not built" >&2; exit 1; }
echo "JNI library: $LIB"

echo "kotlinc: binding + test"
JAVA_HOME="$JDK" kotlinc -nowarn -include-runtime -d "$OUT/golden-test.jar" \
  "$HERE"/src/main/kotlin/dev/agentlean/*.kt "$HERE"/test/GoldenTest.kt

"$JAVA" --enable-native-access=ALL-UNNAMED -Dagentlean.jni.path="$LIB" \
  -Dagentlean.parallel="$([ -n "${AGENTLEAN_SERIAL:-}" ] && echo false || echo true)" \
  -cp "$OUT/golden-test.jar" GoldenTestKt "$ROOT/traces"
