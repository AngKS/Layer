#!/bin/bash
# Runs every measurement of the semantic-tree spec's section 13 on this worktree, quietly, and prints only what the
# benchmark doc needs:
#   - the 1-minute load average before each timed run;
#   - every "BENCH ..." line the tests print;
#   - the canvas workout's CPU Time, Peak (physical memory) and Clock Monotonic Time: the median of 3 runs, each run the
#     average of 5 iterations with its relative standard deviation (Release, CanvasBenchmarkUITests/testCanvasWorkout);
#   - "measure ok: <n> lines" when everything passed. Any failure prints the tail of its log and exits non-zero.
#
# Usage: scripts/measure-semantic-tree.sh [--quick] [--simulator <name>] [--main <worktree>]
#   --quick            leaves out the workout and the load check. Use it to see that every row runs; never to record.
#   --simulator <name> the simulator to time in. Default "Layer iPad Pro 11 (st2-lane-c)"
#                      (19CD922B-1564-4FEF-A86A-4AF37B114B47), where every recorded number is measured.
#   --main <worktree>  also runs, in a temporary copy of that worktree's HEAD, the store benchmark from plan 2 Task 1's
#                      own file (the first commit that added LayerTests/StoreChangeBenchmarkTests.swift, found in this
#                      branch's history) and the workout, under the same conditions. Their lines begin "[main] ".
#
# The conditions (global constraints, "Measuring"):
#   - Without --quick, nothing is timed while the 1-minute load is 20 or more, or while another xcodebuild runs: the
#     script waits up to 15 minutes for the machine to settle, then refuses. Stop other lanes and LM Studio downloads
#     first.
#   - The unit benchmarks run in Debug, alone in their own invocations (the drag counters are process-wide), in this
#     worktree with its own DerivedData (Layer-<worktree folder name>).
#   - The workout needs Release, and Release can't compile LayerTests, so it is built in a temporary worktree of HEAD
#     whose Layer scheme and TestPlans/Layer.xctestplan have LayerTests taken out, as the baseline's was, with a
#     throwaway DerivedData. The app is uninstalled before the runs.
#   - Committed files are never changed: `git status --porcelain` is the same before and after. A workout runs the
#     committed HEAD, so commit first (the script says so when the tree is dirty).
#
# Test hooks, for developing this script: MEASURE_ALLOW_MISSING=1 lets the suites of a plan not yet merged (plan 5's
# SketchConversionBudgetTests) be missing; MEASURE_BUILD_ONLY=1 builds the workout in its temporary worktree and stops there, running nothing.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

QUICK=0
SIM_NAME="Layer iPad Pro 11 (st2-lane-c)"
MAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --simulator) shift; [ $# -gt 0 ] || { echo "--simulator needs a name" >&2; exit 2; }; SIM_NAME="$1" ;;
    --main) shift; [ $# -gt 0 ] || { echo "--main needs a worktree" >&2; exit 2; }; MAIN="$1" ;;
    *) echo "usage: scripts/measure-semantic-tree.sh [--quick] [--simulator <name>] [--main <worktree>]" >&2; exit 2 ;;
  esac
  shift
done

SIM_ID="$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)"
[ -n "$SIM_ID" ] || { echo "No simulator called \"$SIM_NAME\"" >&2; exit 2; }
DESTINATION="platform=iOS Simulator,id=$SIM_ID"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Layer-$(basename "$ROOT")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/measure-semantic-tree.XXXXXX")"
BENCH="$WORK/bench.txt"
: >"$BENCH"
TEMP_WORKTREES=()
cleanup() {
  local tree
  for tree in ${TEMP_WORKTREES[@]+"${TEMP_WORKTREES[@]}"}; do
    git -C "$tree" worktree remove --force "$tree" >/dev/null 2>&1 || git worktree remove --force "$tree" >/dev/null 2>&1 || true
  done
  git worktree prune >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "measure FAILED: $1" >&2
  [ -n "${2:-}" ] && [ -f "$2" ] && tail -40 "$2" >&2
  exit 1
}

git status --porcelain >"$WORK/status-before"

# MARK: Load

load1() { sysctl -n vm.loadavg | awk '{ print $2 }'; }

# Prints the load before a timed run. Without --quick, waits for the machine to be quiet and refuses if it isn't.
quiet_before() {
  local label="$1" waited=0 load
  while :; do
    load="$(load1)"
    if [ "$QUICK" = 1 ] || { [ "${load%%.*}" -lt 20 ] && ! pgrep -x xcodebuild >/dev/null; }; then break; fi
    [ "$waited" -lt 900 ] || fail "not quiet before $label: the 1-minute load is $load, or another xcodebuild is running"
    sleep 20
    waited=$((waited + 20))
  done
  echo "load before $label: $load"
}

# MARK: Running tests

# xcodebuild's pass or failure, and that something ran: a run of 0 tests is a failure.
tests_passed() { grep -Eq '\*\* TEST (EXECUTE )?SUCCEEDED \*\*' "$1" && grep -Eq 'Test run with [1-9][0-9]* tests?' "$1"; }

# build_for_testing <dir> <derived data> <test plan> [configuration]
build_for_testing() {
  local dir="$1" derived="$2" plan="$3" configuration="${4:-Debug}" log="$WORK/build-$RANDOM.log"
  (cd "$dir" && xcodebuild build-for-testing -project Layer.xcodeproj -scheme Layer -testPlan "$plan" \
    -configuration "$configuration" -destination "$DESTINATION" -derivedDataPath "$derived" \
    -skipPackagePluginValidation) >"$log" 2>&1 || fail "the $configuration build in $dir" "$log"
}

# run_group <dir> <derived data> <label> <only-testing...>: one timed invocation of the unit tests. Its BENCH lines
# are kept; $LAST_LOG is its log.
LAST_LOG=""
run_group() {
  local dir="$1" derived="$2" label="$3" prefix="$4" log="$WORK/group-$RANDOM.log" args=() item
  shift 4
  for item in "$@"; do args+=("-only-testing:LayerTests/$item"); done
  quiet_before "$label"
  (cd "$dir" && TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild test-without-building -project Layer.xcodeproj -scheme Layer \
    -testPlan CI -destination "$DESTINATION" -derivedDataPath "$derived" -skipPackagePluginValidation \
    "${args[@]}") >"$log" 2>&1 || fail "$label" "$log"
  tests_passed "$log" || fail "$label ran no tests, or did not succeed" "$log"
  grep -E '^BENCH ' "$log" | sed "s/^/$prefix/" | tee -a "$BENCH"
  LAST_LOG="$log"
}

# Fails unless the lines kept by the last group include one starting with each pattern.
require_lines() {
  local label="$1" pattern
  shift
  for pattern in "$@"; do
    grep -q "^BENCH $pattern" "$LAST_LOG" || fail "$label printed no line beginning \"BENCH $pattern\"" "$LAST_LOG"
  done
}

# MARK: The workout

# A temporary worktree of <repo>'s HEAD; its path in $TEMP_TREE.
TEMP_TREE=""
temporary_worktree() {
  TEMP_TREE="$WORK/tree-$RANDOM"
  git -C "$1" worktree add --detach "$TEMP_TREE" HEAD >/dev/null 2>&1 || fail "a temporary worktree of $1"
  TEMP_WORKTREES+=("$TEMP_TREE")
}

# Takes LayerTests out of the Layer scheme's build entries and out of TestPlans/Layer.xctestplan, in a temporary worktree.
take_out_layer_tests() {
  python3 -I - "$1" <<'PYTHON' || fail "taking LayerTests out of the scheme and the Layer test plan"
import json, re, sys
tree = sys.argv[1]
scheme = tree + "/Layer.xcodeproj/xcshareddata/xcschemes/Layer.xcscheme"
text = open(scheme).read()
entries = re.findall(r"<BuildActionEntry\b.*?</BuildActionEntry>", text, re.S)
doomed = [e for e in entries if 'BlueprintName = "LayerTests"' in e]
if len(doomed) != 1:
    sys.exit("expected one LayerTests build entry, found %d" % len(doomed))
open(scheme, "w").write(text.replace(doomed[0], "", 1))
plan_path = tree + "/TestPlans/Layer.xctestplan"
plan = json.load(open(plan_path))
kept = [t for t in plan["testTargets"] if t["target"]["name"] != "LayerTests"]
if len(kept) != len(plan["testTargets"]) - 1:
    sys.exit("expected one LayerTests target in the Layer test plan")
plan["testTargets"] = kept
json.dump(plan, open(plan_path, "w"), indent=2)
PYTHON
}

# workout <worktree whose HEAD to run> <label prefix>: builds Release in a temporary worktree and runs the workout 3 times.
workout() {
  local source="$1" prefix="$2" derived="$WORK/dd-release-$RANDOM" tree run log metrics="$WORK/metrics-$RANDOM.txt"
  if [ -n "$(git -C "$source" status --porcelain)" ]; then
    echo "note: ${prefix}the workout runs the committed HEAD $(git -C "$source" rev-parse --short HEAD); uncommitted changes in $source are not in it"
  fi
  temporary_worktree "$source"
  tree="$TEMP_TREE"
  take_out_layer_tests "$tree"
  build_for_testing "$tree" "$derived" Layer Release
  [ "${MEASURE_BUILD_ONLY:-0}" != 1 ] || { echo "${prefix}workout built (MEASURE_BUILD_ONLY)"; return 0; }
  xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$SIM_ID" kahshin.Layer >/dev/null 2>&1 || true
  : >"$metrics"
  for run in 1 2 3; do
    log="$WORK/workout-$RANDOM.log"
    quiet_before "${prefix}workout run $run"
    (cd "$tree" && TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild test-without-building -project Layer.xcodeproj -scheme Layer \
      -testPlan Layer -configuration Release -destination "$DESTINATION" -derivedDataPath "$derived" \
      -skipPackagePluginValidation -only-testing:LayerUITests/CanvasBenchmarkUITests/testCanvasWorkout) >"$log" 2>&1 \
      || fail "${prefix}workout run $run" "$log"
    grep -Eq '\*\* TEST (EXECUTE )?SUCCEEDED \*\*' "$log" || fail "${prefix}workout run $run did not succeed" "$log"
    # "... measured [CPU Time, s] average: 4.496, relative standard deviation: 8.7%, values: [...]"
    grep -E "measured \[.*\] average: " "$log" | sed -E 's/.*measured \[([^]]*)\] average: ([0-9.eE+-]+), relative standard deviation: ([0-9.eE+-]+)%.*/\1|\2|\3/' \
      | sed "s/\$/|$run/" >>"$metrics"
  done
  local family found=0 line
  for family in "CPU Time" "Peak" "Clock Monotonic Time"; do
    line="$(grep -F "$family" "$metrics" | awk -F'|' -v prefix="$prefix" '
      { name = $1; value[NR] = $2; spread[NR] = $3 ; n++ }
      END {
        if (n == 0) exit 1
        for (i = 1; i <= n; i++) sorted[i] = value[i]
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (sorted[j] + 0 < sorted[i] + 0) { t = sorted[i]; sorted[i] = sorted[j]; sorted[j] = t }
        median = (n % 2) ? sorted[(n + 1) / 2] : (sorted[n / 2] + sorted[n / 2 + 1]) / 2
        runs = ""
        for (i = 1; i <= n; i++) runs = runs (i > 1 ? ", " : "") value[i] " (" spread[i] "%)"
        printf "%sworkout %s: median %s of %d runs [%s]\n", prefix, name, median, n, runs
      }')" || fail "${prefix}the workout reported no \"$family\" metric" "$log"
    echo "$line"
    found=$((found + 1))
  done
  [ "$found" = 3 ] || fail "${prefix}the workout's metrics"
}

if [ "${MEASURE_BUILD_ONLY:-0}" = 1 ]; then
  workout "$ROOT" ""
  exit 0
fi

# MARK: The unit measurements, on this worktree

echo "measuring $(git rev-parse --short HEAD) in \"$SIM_NAME\" ($SIM_ID)$([ "$QUICK" = 1 ] && echo ", quick")"
build_for_testing "$ROOT" "$DERIVED" CI

run_group "$ROOT" "$DERIVED" "the store benchmark" "" StoreChangeBenchmarkTests
require_lines "the store benchmark" "store move " "store resize " "store text " "store add " \
  "large move " "large resize " "large text " "large add " "large look " "large token " "large titleSize " "large drag " \
  "large dropTarget " "large siriElements "

run_group "$ROOT" "$DERIVED" "the budgets and the rules" "" StoreChangeBudgetTests "TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick()"
require_lines "the budgets" "tree move " "tree resize " "tree text " "tree add " "rules edit "

run_group "$ROOT" "$DERIVED" "the drag frame benchmark" "" HostedWindowSuites/DragFrameBenchmarkTests
require_lines "the drag frame benchmark" "drag line " "drag group " "drag rowChild "

run_group "$ROOT" "$DERIVED" "the drag and node-view counters" "" \
  CanvasDragWorkTests HostedWindowSuites/CanvasTargetsWorkTests NodeViewTests HostedWindowSuites/NodeViewWorkTests LayoutDragTests
require_lines "the counters" "drag line " "drag group " "drag row child " "node views "

SKETCH_SUITES=("SketchBenchmarkTests/printsTheFullBenchmarkReport()")
SKETCH_LINES=("sketch accuracy ")
if [ -f LayerTests/SketchConversionBudgetTests.swift ]; then
  SKETCH_SUITES+=(SketchConversionBudgetTests)
  SKETCH_LINES+=("sketch reading " "structure pass ")
elif [ "${MEASURE_ALLOW_MISSING:-0}" = 1 ]; then
  echo "note: LayerTests/SketchConversionBudgetTests.swift (plan 5) is not in this tree; its two lines are left out"
else
  fail "LayerTests/SketchConversionBudgetTests.swift (plan 5) is not in this tree, so \"BENCH sketch reading\" and \"BENCH structure pass\" can't be measured"
fi
run_group "$ROOT" "$DERIVED" "the sketch reading" "" "${SKETCH_SUITES[@]}"
require_lines "the sketch reading" "${SKETCH_LINES[@]}"

run_group "$ROOT" "$DERIVED" "generation through the reconciler" "" GenerationThroughTheReconcilerTests
echo "generation: GenerationThroughTheReconcilerTests passed"

# MARK: The workout, and main

if [ "$QUICK" != 1 ]; then
  workout "$ROOT" ""
fi

if [ -n "$MAIN" ]; then
  MAIN="$(cd "$MAIN" && pwd)" || fail "no such worktree: $MAIN"
  SHA="$(git log --diff-filter=A --format=%H -- LayerTests/StoreChangeBenchmarkTests.swift | tail -1)"
  [ -n "$SHA" ] || fail "plan 2 Task 1's StoreChangeBenchmarkTests.swift is not in this branch's history"
  temporary_worktree "$MAIN"
  MAIN_TREE="$TEMP_TREE"
  git show "$SHA:LayerTests/StoreChangeBenchmarkTests.swift" >"$MAIN_TREE/LayerTests/StoreChangeBenchmarkTests.swift" \
    || fail "reading StoreChangeBenchmarkTests.swift at $SHA"
  (cd "$MAIN_TREE" && xcodegen generate >"$WORK/xcodegen.log" 2>&1) || fail "xcodegen in the copy of main" "$WORK/xcodegen.log"
  MAIN_DERIVED="$WORK/dd-main"
  build_for_testing "$MAIN_TREE" "$MAIN_DERIVED" CI
  run_group "$MAIN_TREE" "$MAIN_DERIVED" "main's store benchmark ($SHA)" "[main] " StoreChangeBenchmarkTests
  require_lines "main's store benchmark" "store move " "store resize " "store text " "store add "
  if [ "$QUICK" != 1 ]; then
    workout "$MAIN" "[main] "
  fi
fi

# MARK: The end

git status --porcelain >"$WORK/status-after"
cmp -s "$WORK/status-before" "$WORK/status-after" || fail "git status --porcelain changed while measuring"
echo "measure ok: $(wc -l <"$BENCH" | tr -d ' ') lines"
