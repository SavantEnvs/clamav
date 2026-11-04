#!/usr/bin/env bash
#
# mayhem/build.sh — builds ClamAV's 39 libFuzzer targets (upstream fuzz/CMakeLists.txt, the OSS-Fuzz set),
# a run-once `-standalone` reproducer for each, and the project's own test suite (normal flags).
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Re-runnable and air-gapped:
# the rust crates are resolved from $CARGO_HOME (baked in the image by the first, online run).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${RUSTUP_HOME:=/opt/toolchains/rust/rustup}"
: "${CARGO_HOME:=/opt/toolchains/rust/cargo}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS RUSTUP_HOME CARGO_HOME
export PATH="$CARGO_HOME/bin:$PATH"
# Tells upstream's CMake (ENABLE_FUZZ) not to add its own `-fsanitize=$SANITIZER,fuzzer-no-link`.
export FUZZING_ENGINE=libfuzzer

cd "$SRC"
# CMake takes the compiler from CC/CXX (by name, via PATH); passing -DCMAKE_C_COMPILER=clang makes a re-run wipe the cache.
FB="$SRC/build/fuzz"
TB="$SRC/build/tests"

# 1) The project, sanitized, with SanCov (fuzzer-no-link) on libclamav. lsan_off.o rides in the exe linker
#    flags so every fuzz and -standalone binary links it.
#    CVD_CERTS_DIRECTORY points CERTSDIR at upstream's in-tree certs/: cl_load() builds a code-signing
#    verifier from CERTSDIR and fails every call with CL_ECVD when that directory is missing (the default,
#    /usr/local/etc/certs, is absent from the image), which left every dbload target at 0 edges.
mkdir -p "$FB"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FB/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FB/standalone_main.o"
cmake -S "$SRC" -B "$FB" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $FB/lsan_off.o" \
    -DCVD_CERTS_DIRECTORY="$SRC/certs" \
    -DENABLE_FUZZ=ON
cmake --build "$FB" -j"$MAYHEM_JOBS"

# 2) Relink every harness twice from CMake's own link lines: against libFuzzer (/mayhem/<t>) and against
#    the run-once driver (/mayhem/<t>-standalone). The rust staticlib is relinked from a copy whose
#    prebuilt std/core members (DWARF 4) have their debug info dropped (DWARF must stay <= 3).
RUST_LIB=$(find "$FB" -name libclamav_rust.a -path '*release*' | head -n1)
STRIPPED="$FB/libclamav_rust.stripped.a"
cp -f "$RUST_LIB" "$STRIPPED"
chmod u+w "$STRIPPED"
tmp=$(mktemp -d)
(
    cd "$tmp"
    ar x "$STRIPPED"
    ls ./*.o | xargs -P "$MAYHEM_JOBS" -n 64 bash -c '
        for m; do
            v=$(readelf --debug-dump=info "$m" 2>/dev/null | grep -m1 -oE "Version: +[0-9]+" | grep -oE "[0-9]+$" || true)
            [ -n "$v" ] && [ "$v" -ge 4 ] && echo "$m"
        done; true' _ | sed 's#^\./##' > members.txt
    xargs -r -n1 objcopy --strip-debug < members.txt
    xargs -r ar rs "$STRIPPED" < members.txt
)
rm -rf "$tmp"

# $1 = target, $2 = "fuzz" | "standalone"
relink() {
    local t="$1" link
    cd "$FB/fuzz"
    link=$(cat "CMakeFiles/$t.dir/link.txt")
    link=${link//$(grep -o '[^ ]*libclamav_rust\.a' <<<"$link" | head -n1)/$STRIPPED}
    if [ "$2" = standalone ]; then
        link=${link/ -fsanitize=fuzzer / $FB/standalone_main.o }
        link=${link/ -o $t / -o $SRC/$t-standalone }
    else
        link=${link/ -o $t / -o $SRC/$t }
    fi
    eval "$link"
}
export -f relink
export FB SRC STRIPPED
TARGETS=$(cd "$FB/fuzz/CMakeFiles" && ls -d clamav_*_fuzzer.dir | sed 's/\.dir$//')
for kind in fuzz standalone; do
    echo "$TARGETS" | xargs -P "$MAYHEM_JOBS" -I{} bash -c "relink {} $kind"
done

# CMake's own links are redundant now; drop them (~1.7 GB). A re-run relinks them.
rm -f "$FB"/fuzz/clamav_*_fuzzer

# 3) The test suite, with the project's NORMAL flags (clean, independent build). test.sh only runs it.
cmake -S "$SRC" -B "$TB" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DENABLE_TESTS=ON -DENABLE_MILTER=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_CLAMONACC=OFF -DENABLE_SYSTEMD=OFF
cmake --build "$TB" -j"$MAYHEM_JOBS"
