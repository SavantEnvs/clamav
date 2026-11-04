#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS ClamAV's own suite (every ctest the build registers: libclamav check tests, the
# clamscan/sigtool/clamd/freshclam/clamsubmit pytest suites and libclamav_rust's cargo tests, built by
# mayhem/build.sh into build/tests) plus known-answer probes of the built sigtool and clamscan.
# clamd/freshclam/clamsubmit use loopback mocks only and libclamav_rust has no external crates, so the whole
# suite runs offline.
# exit 0 = pass.
#
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


TB="$SRC/build/tests"
SIGTOOL="$TB/sigtool/sigtool"
CLAMSCAN="$TB/clamscan/clamscan"
for b in "$SIGTOOL" "$CLAMSCAN"; do
  [ -x "$b" ] || { echo "missing $b — mayhem/build.sh did not build the test suite" >&2; emit_ctrf "clamav" 0 1 0; exit 1; }
done

passed=0; failed=0; skipped=0

# 1) upstream's suite, all of it, through ctest: libclamav (check), clamscan/sigtool/clamd/freshclam/clamsubmit
#    (pytest) and libclamav_rust (cargo test). Summary lines are pytest's `=== N passed, M skipped in Ts ===`
#    and cargo's `test result: ok. N passed; M failed; K ignored; ...`.
log=$(mktemp)
(cd "$TB" && ctest -V) > "$log" 2>&1
ctest_rc=$?
tail -n 5 "$log"
while read -r line; do
  n=$(grep -oE '[0-9]+ passed' <<<"$line" | grep -oE '[0-9]+' || true);  passed=$(( passed + ${n:-0} ))
  n=$(grep -oE '[0-9]+ failed' <<<"$line" | grep -oE '[0-9]+' || true);  failed=$(( failed + ${n:-0} ))
  n=$(grep -oE '[0-9]+ errors?' <<<"$line" | grep -oE '[0-9]+' || true); failed=$(( failed + ${n:-0} ))
  n=$(grep -oE '[0-9]+ skipped' <<<"$line" | grep -oE '[0-9]+' || true); skipped=$(( skipped + ${n:-0} ))
done < <(grep -E '^[0-9]+: =+ .* in [0-9.]+s' "$log")
while read -r line; do
  n=$(grep -oE '[0-9]+ passed' <<<"$line" | grep -oE '[0-9]+' || true);  passed=$(( passed + ${n:-0} ))
  n=$(grep -oE '[0-9]+ failed' <<<"$line" | grep -oE '[0-9]+' || true);  failed=$(( failed + ${n:-0} ))
  n=$(grep -oE '[0-9]+ ignored' <<<"$line" | grep -oE '[0-9]+' || true); skipped=$(( skipped + ${n:-0} ))
done < <(grep -E '^[0-9]+: test result: ' "$log")
rm -f "$log"
if [ "$ctest_rc" -ne 0 ]; then failed=$(( failed + 1 )); fi
if [ "$passed" -lt 100 ]; then echo "suspiciously few passing upstream tests: $passed" >&2; failed=$(( failed + 1 )); fi

# 2) known-answer probes on the built binaries (a no-op/exit(0) program cannot satisfy these).
export CVD_CERTS_DIR="$SRC/certs"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'ClamAV KAT probe\n' > "$work/hit.bin"
printf 'other data\n'      > "$work/miss.bin"
echo '2062080bf12c7fa0e87326706d8b1c40:17:ClamAV.KAT.Hdb' > "$work/kat.hdb"
echo 'ClamAV.KAT.Ndb:0:*:4b41542070726f6265'               > "$work/kat.ndb"

check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$(( passed + 1 )); else failed=$(( failed + 1 )); echo "FAIL $1: expected [$2] got [$3]" >&2; fi
}
check sigtool-md5    '2062080bf12c7fa0e87326706d8b1c40:17:hit.bin' "$(cd "$work" && "$SIGTOOL" --md5 hit.bin 2>/dev/null)"
check sigtool-sha256 '36526143d62df7c527bca99a77da3da4402272b99b115e18fa59a4ed468133be:17:hit.bin' "$(cd "$work" && "$SIGTOOL" --sha256 hit.bin 2>/dev/null)"
check sigtool-sha1   'cdf9f98618207f0a66996c672f79ea6b391ac060:17:hit.bin' "$(cd "$work" && "$SIGTOOL" --sha1 hit.bin 2>/dev/null)"
for db in kat.hdb kat.ndb; do
  out=$("$CLAMSCAN" -d "$work/$db" --no-summary "$work/hit.bin" 2>/dev/null); rc=$?
  check "clamscan-$db-hit"  "$work/hit.bin: ClamAV.KAT.$([ $db = kat.hdb ] && echo Hdb || echo Ndb).UNOFFICIAL FOUND rc=1" "$out rc=$rc"
  out=$("$CLAMSCAN" -d "$work/$db" --no-summary "$work/miss.bin" 2>/dev/null); rc=$?
  check "clamscan-$db-miss" "$work/miss.bin: OK rc=0" "$out rc=$rc"
done

emit_ctrf "clamav" "$passed" "$failed" "$skipped"
