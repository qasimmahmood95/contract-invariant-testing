#!/usr/bin/env bash
# Falsification harness (M4) — CLAUDE.md hard limit 3: a test that cannot
# fail must not merge. Each FALSIFY=<id> lever sabotages the harness side of
# exactly one property; the SUT=eager run points the untouched campaign at
# the planted defect (test/defect/EagerTimelockController.sol). Every run
# below must go RED; a green run means a dead lever — a vacuous-pass risk —
# and the harness exits non-zero.
#
# Lever runs redirect Foundry failure persistence into $OUT so they never
# touch the committed defect corpus (test/failures/), which the defect run
# replays and must leave byte-for-byte unchanged (verified via git diff).
set -uo pipefail
cd "$(dirname "$0")/.."

OUT=${FALSIFY_OUT:-falsify-out}
rm -rf "$OUT"
mkdir -p "$OUT"
failures=0

expect_red() {
  local label="$1"
  shift
  local log="$OUT/$label.log"
  if env "$@" >"$log" 2>&1; then
    echo "DEAD LEVER: $label stayed green ($log)"
    failures=$((failures + 1))
  else
    echo "red: $label — $(grep -m1 -oE '\[FAIL[^]]*' "$log" | head -c 100)"
  fi
}

for n in 1 2 3 4 5 6 7 8; do
  expect_red "INV-$n" \
    FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$OUT/corpus" \
    FALSIFY="INV-$n" forge test --match-test "invariant_INV${n}_"
done

for n in 1 2 3 4 5 6; do
  expect_red "FZ-$n" \
    FOUNDRY_FUZZ_FAILURE_PERSIST_DIR="$OUT/corpus" \
    FALSIFY="FZ-$n" forge test --match-test "testFuzz_FZ${n}_"
done

# The planted defect: the standard campaign against EagerTimelockController
# replays the committed counterexample (test/failures/) and must fail INV-1.
expect_red "defect-inv1" SUT=eager forge test --match-test invariant_INV1_delayIntegrity

if ! git diff --exit-code --quiet -- test/failures/; then
  echo "REPLAY DRIFT: the defect run rewrote the committed corpus"
  failures=$((failures + 1))
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "FALSIFY: $failures dead lever(s)/drift(s) — a property cannot fail; do not merge"
  exit 1
fi
echo "FALSIFY: all 15 runs red, committed corpus replayed byte-for-byte — every property can fail"
