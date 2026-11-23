# Semantic tree: performance baseline and budgets

Spec §13. The "Before" column was measured on main 8d00fc7 (2026-11-23, Xcode 27.2, iOS 27.2 simulator
"Layer iPad Pro 11 (st2-lane-c)", UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47). The "After" columns
are filled when plan 2 and plan 6 end, with the same simulator and the same commands.

| What | How | Budget | Before (main 8d00fc7) | After plan 2 | After plan 6 |
|---|---|---|---|---|---|
| Reading after the pen rests (rules path, no model) | `SketchBenchmark` timings over the 156 fixtures, plus the conversion including the structure pass | p95 under 100 ms | not measured in this baseline (it needs the tree) | not measured: plan 5 puts the reading on the tree | — |
| Layout of one edit on a 100-node screen: the store | `StoreChangeBenchmarkTests`, 50 runs each, `ContinuousClock` | p95 under 16 ms in the simulator; checked on the iPad | move p50 0.174 ms, p95 0.183 ms; resize p50 0.175 ms, p95 0.186 ms; text p50 0.175 ms, p95 0.185 ms; add (and delete) p50 0.333 ms, p95 0.353 ms | move p50 0.433 ms, p95 0.457 ms; resize p50 0.429 ms, p95 0.464 ms; text p50 0.430 ms, p95 0.450 ms; add (and delete) p50 0.544 ms, p95 0.571 ms (median of three runs). About 2.5 times main, and within budget (see below) | — |
| Layout of one edit on a 100-node screen: the rules | plan 1's `TreeRulesTests.oneEditOnAHundredNodeScreenIsQuick` (at 130a4f1, from plan 1's ledger) | p95 under 16 ms | p50 0.957 ms, p95 1.292 ms | p50 0.646 ms, p95 0.820 ms (median of three runs, on this branch) | — |
| A drag frame | `CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` | today's numbers or better | a 60-frame drag of a group of three writes 240 elements (60 x 4: three lines and the group's box); a drag of one line writes 60 | a group of three writes 60 (the group alone, its lines riding in it); one line writes 60. A leaf dragged 60 frames on a free screen lays out its screen's root 60 times and the screen's other four containers 0 times (`StoreChangeBudgetTests.aLeafDragLaysOutOnlyItsDirtyPath`). A 60-frame drag of several lines, a twist and a group's handle each build the store's index at most once (`CanvasDragWorkTests.aGesturesFramesBuildTheIndexOnlyWhenAContainerMoves`) | — |
| Streaming generation | ids of unaffected nodes are stable across updates; one commit per update; layout off the main actor | 100% stable | not measured in this baseline | not measured: plan 3 streams generation through the tree | — |
| Generation tokens and time to first content | `ScreenBenchmarkHarness` on macOS | recorded, and the hosted default chosen from them | not measured in this baseline | not measured: plan 3 builds the harness on the tree | — |
| One change through the store on a 100-node column screen, on the tree | `StoreChangeBudgetTests.aStoreChangeOnAHundredNodeScreenIsWithinBudget` (always on), 50 runs each: a leaf moved (laid back by its row), a body resized, a text edited, a text added to a row | p95 under 16 ms | not measurable on main (it needs the tree) | move p50 0.161 ms, p95 0.196 ms; resize p50 0.874 ms, p95 0.966 ms; text p50 0.912 ms, p95 1.012 ms; add p50 0.791 ms, p95 0.881 ms (median of three runs) | — |
| Canvas workout | `CanvasBenchmarkUITests.testCanvasWorkout`, Release, 5 iterations a run, median of 3 runs | no worse than baseline by more than 5% | CPU time 4.479 s; peak physical memory 84.65 MB; clock 30.233 s (see below) | CPU time 4.777 s; peak physical memory 84.79 MB; clock 30.437 s. CPU time is 6.7% over the Before column, and 0.4% over main measured again in the same hour on the same simulator (4.757 s): see below | — |

## How the baseline was measured

- Machine quiet before each measurement: the 1-minute load average was 14 before the first unit run
  (the other two unit runs were at about 50, which is why the result is shown not to depend on it, below),
  and 14.92, 9.07 and 8.03 before the three workout runs; it stayed between 7 and 20 during them. No other `xcodebuild` ran during the workout runs.
- The same simulator for every measurement. Before the workout runs the app was uninstalled; the
  simulator was not erased.
- The unit benchmark is the single-threaded work of a few hundred microseconds. Three runs, at
  1-minute loads of about 14, 50 and 49, gave the same numbers to within 3% (p50 and p95 above are the
  first run; the other two: move p50 0.172 and 0.175, p95 0.183 and 0.184; add p50 0.333 and 0.337, p95
  0.353 and 0.357), so it does not move with the machine's load.
- The workout needs Release, and Release cannot compile `LayerTests` (it uses debug-only symbols).
  So on the baseline worktree only, `LayerTests` was taken out of the `Layer` scheme's build entries and
  out of `TestPlans/Layer.xctestplan`. Do the same for the "after" runs, and not in the committed files.
- Commands (replace the simulator with the one above, and the DerivedData with a throwaway folder):

```
# once, with LayerTests taken out of the scheme and the Layer test plan:
TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild build-for-testing -project Layer.xcodeproj -scheme Layer \
  -testPlan Layer -configuration Release \
  -destination "platform=iOS Simulator,id=19CD922B-1564-4FEF-A86A-4AF37B114B47" \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Layer-<name>-release" -skipPackagePluginValidation
xcrun simctl uninstall 19CD922B-1564-4FEF-A86A-4AF37B114B47 kahshin.Layer
TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild test-without-building ...same arguments... \
  -only-testing:LayerUITests/CanvasBenchmarkUITests/testCanvasWorkout

# the store benchmark (Debug, unit tests):
TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,id=19CD922B-1564-4FEF-A86A-4AF37B114B47" \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Layer-<name>" -skipPackagePluginValidation \
  -only-testing:LayerTests/StoreChangeBenchmarkTests
```

## Canvas workout, three runs (each: average of 5 iterations, relative standard deviation in brackets)

| Run | CPU time s | Peak physical MB | Clock s | CPU instructions G | CPU cycles G |
|---|---|---|---|---|---|
| 1 | 4.496 (8.7%) | 84.75 (0.56%) | 30.098 (6.7%) | 25.45 (4.9%) | 15.49 (8.1%) |
| 2 | 4.467 (7.4%) | 84.62 (0.59%) | 30.233 (6.8%) | 25.53 (3.8%) | 15.52 (8.1%) |
| 3 | 4.479 (8.0%) | 84.65 (0.59%) | 30.291 (7.1%) | 25.55 (3.9%) | 15.66 (8.5%) |
| Median | 4.479 | 84.65 | 30.233 | 25.53 | 15.52 |

Run to run, CPU time varies by under 1% and peak memory by under 0.2%, so a 5% budget is well outside
the noise. Within a run the iterations vary by 4 to 9%.

The store benchmark's operations: `update(ref) { $0.frame.origin.x += 1 }`, `{ $0.frame.size.width += 1 }`,
`{ $0.text += "a" }`, and one text added with `setElements([text], on:, replacing: false)` then deleted,
on an iPhone screen of 25 rows of 4 elements (a text, a body, a toggle, a divider).

## How plan 2's numbers were measured

On feature/semantic-tree 9939ada (2026-11-24, Xcode 27.2, the same simulator, UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47),
with the commands above. The host is an Apple M4 Max (12 performance and 4 efficiency cores).

- Machine quiet: measuring began only after two checks a minute apart found a 1-minute load at most 20 and no other
  `xcodebuild` running (another lane's UI suite ran until 03:12, so the wait was 36 minutes). The load was then sampled
  every 20 seconds through every run. Runs during which it rose above 20 were discarded and run again: the branch's run 3
  (load up to 25.5) and main's run 1 (up to 35.9). No other `xcodebuild` ran during any run.
- The unit benchmarks ran in Debug, three times each, at 1-minute loads of 7 to 17. The store benchmark's runs agree
  within 4% at p50 and 10% at p95; the rules' and the tree's, which are a fraction of a millisecond, within 13% at p50
  and 28% at p95. `StoreChangeBenchmarkTests` runs alone; `TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick()` and
  `StoreChangeBudgetTests` run together after it.
  - Store, move p50 0.429 / 0.433 / 0.434 ms, p95 0.447 / 0.465 / 0.457; resize p50 0.429 / 0.427 / 0.444,
    p95 0.441 / 0.483 / 0.464; text p50 0.430 / 0.430 / 0.432, p95 0.448 / 0.450 / 0.490; add p50 0.540 / 0.544 / 0.549,
    p95 0.557 / 0.571 / 0.602.
  - Rules p50 0.693 / 0.646 / 0.634 ms, p95 0.892 / 0.820 / 0.707.
  - On the tree: move p50 0.161 / 0.162 / 0.143 ms, p95 0.201 / 0.196 / 0.157; resize p50 0.863 / 0.874 / 0.883,
    p95 1.011 / 0.966 / 0.949; text p50 0.907 / 0.912 / 0.924, p95 0.993 / 1.012 / 1.012; add p50 0.791 / 0.796 / 0.787,
    p95 0.891 / 0.881 / 0.870.
- A change through the store costs about 2.5 times what it did on main (0.43 ms against 0.17 ms for a move). Each change
  on the branch writes through the projection, runs the tree's rules and compares the tree, and the next read lowers the
  tree again once. It is still about 35 times under the 16 ms budget.
- Nested fit rows (plan 1's final review: their measuring grows polynomially with depth) caused no regression seen
  here. Nothing measured nests fit rows more than one deep: rows in a column, and a row in a card.

## Canvas workout after plan 2, and main again in the same hour

The branch built in Release from a temporary worktree (DerivedData `Layer-semantic-tree-release`), and main 8d00fc7
the same way (`Layer-st2-main-control-release`), each with `LayerTests` taken out of the scheme and the Layer test
plan there only. The app was uninstalled before every run.

| Run | CPU time s | Peak physical MB | Clock s | CPU instructions G | CPU cycles G |
|---|---|---|---|---|---|
| Branch 1 | 4.850 (6.8%) | 84.79 (0.64%) | 30.493 (6.7%) | 25.68 (3.8%) | 13.78 (6.9%) |
| Branch 2 | 4.777 (8.4%) | 84.73 (0.64%) | 30.436 (6.9%) | 25.51 (3.4%) | 13.79 (4.3%) |
| Branch 4 | 4.773 (6.9%) | 85.04 (0.54%) | 30.437 (6.6%) | 25.53 (3.7%) | 13.61 (6.1%) |
| **Branch median** | **4.777** | **84.79** | **30.437** | **25.53** | **13.78** |
| Main 2 | 4.742 (6.9%) | 84.33 (0.42%) | 30.437 (6.7%) | 25.51 (3.6%) | 13.85 (6.4%) |
| Main 3 | 4.775 (7.1%) | 84.80 (0.58%) | 30.460 (6.7%) | 25.59 (3.5%) | 13.58 (5.2%) |
| Main 4 | 4.757 (7.0%) | 83.94 (0.51%) | 30.526 (6.7%) | 25.56 (3.6%) | 13.56 (5.9%) |
| **Main median, again** | **4.757** | **84.33** | **30.460** | **25.56** | **13.58** |
| Discarded: branch 3, main 1 | 4.677, 4.769 | 85.27, 84.58 | 30.518, 30.462 | 25.58, 25.60 | 14.28, 13.68 |

Against the Before column the branch's CPU time is 6.7% higher, over the 5% budget. Against main measured again in
the same hour it is 0.4% higher, within it. Main itself now takes 6.2% more CPU time than it did on 2026-11-23 for
the same instructions (25.56 G against 25.53 G) in 12.5% fewer cycles: the cores ran at about 2.86 GHz on average
against 3.47 GHz then. So the difference from the Before column is the machine, not the code: the branch retires the
same instructions as main (25.53 G against 25.56 G), and its peak memory and clock are within 1% of main's.

