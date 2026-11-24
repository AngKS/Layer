# Semantic tree: performance baseline and budgets

Spec §13. The "Before" column was measured on main 8d00fc7 (2026-11-23, Xcode 27.2, iOS 27.2 simulator
"Layer iPad Pro 11 (st2-lane-c)", UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47). The "After" columns
are filled when plans 2, 3, 4, 5 and 6 end, with the same simulator and the same commands; plan 3's generation figures come
from `Tools/ScreenBenchmarkHarness` on macOS, where the on-device model runs.

| What | How | Budget | Before (main 8d00fc7) | After plan 2 | After plan 3 | After plan 4 | After plan 5 | After plan 6 |
|---|---|---|---|---|---|---|---|---|
| Reading after the pen rests (rules path, no model) | `SketchBenchmark` timings over the 156 fixtures, plus the conversion including the structure pass | p95 under 100 ms | not measured in this baseline (it needs the tree) | not measured: plan 5 puts the reading on the tree | not measured: plan 5 puts the reading on the tree | not measured: plan 5 puts the reading on the tree | the rules' reading p50 0.0019 ms, p95 0.0147 ms over the 156 fixtures (`SketchBenchmarkTests.printsTheFullBenchmarkReport`). The conversion on a free iPhone screen of 100 sketched things, over the 116 fixtures the rules read as a thing on a screen (`SketchConversionBudgetTests.aReadingLandsWithinBudget`): the reading, the landing and the structure pass, as one step, p50 1.567 ms, p95 2.214 ms, 45 times under the budget; the pass alone p50 0.005 ms, p95 0.165 ms (medians of three runs). The corpus: rules 87.8% (137/156), with Apple Intelligence on this Mac 89.1% (139/156); the 32 structure fixtures all as expected. See "How plan 5's numbers were measured" | — |
| Layout of one edit on a 100-node screen: the store | `StoreChangeBenchmarkTests`, 50 runs each, `ContinuousClock`: each change alone, and (since the fix wave) with the next read of the screens after it, a `+read` line | p95 under 16 ms in the simulator; checked on the iPad | move p50 0.174 ms, p95 0.183 ms; resize p50 0.175 ms, p95 0.186 ms; text p50 0.175 ms, p95 0.185 ms; add (and delete) p50 0.333 ms, p95 0.353 ms. The change alone: no read was timed | move p50 0.433 ms, p95 0.457 ms; resize p50 0.429 ms, p95 0.464 ms; text p50 0.430 ms, p95 0.450 ms; add (and delete) p50 0.544 ms, p95 0.571 ms (median of three runs). The change alone. About 2.5 times main, and within budget (see below). The next read adds about 0.17 ms (fix wave, below) | move p50 0.280 ms, p95 0.299 ms; resize p50 0.287 ms, p95 0.307 ms; text p50 0.275 ms, p95 0.317 ms; add (and delete) p50 0.559 ms, p95 0.609 ms (median of three runs, the change alone). With the next read: move p95 0.477 ms, resize 0.483 ms, text 0.512 ms, add 0.791 ms. As plan 2's fix wave left it (see "How plan 3's numbers were measured") | move p50 0.289 ms, p95 0.307 ms; resize p50 0.287 ms, p95 0.298 ms; text p50 0.284 ms, p95 0.294 ms; add (and delete) p50 0.582 ms, p95 0.603 ms (median of three runs, the change alone). With the next read: move p95 0.489 ms, resize 0.479 ms, text 0.470 ms, add 0.783 ms. Within 5% of plan 3's: plan 4 changed no edit's path (see "How plan 4's numbers were measured") | move p50 0.335 ms, p95 0.356 ms; resize p50 0.338 ms, p95 0.353 ms; text p50 0.330 ms, p95 0.339 ms; add (and delete) p50 0.637 ms, p95 0.662 ms (median of three runs, the change alone). With the next read: move p95 0.533 ms, resize 0.530 ms, text 0.517 ms, add 0.839 ms. 0.046 to 0.055 ms over plan 4's: every change now runs the decline check (see "How plan 5's numbers were measured") | — |
| Layout of one edit on a 100-node screen: the rules | plan 1's `TreeRulesTests.oneEditOnAHundredNodeScreenIsQuick` (at 130a4f1, from plan 1's ledger) | p95 under 16 ms | p50 0.957 ms, p95 1.292 ms | p50 0.646 ms, p95 0.820 ms (median of three runs, on this branch) | p50 0.633 ms, p95 0.719 ms (median of three runs) | p50 0.661 ms, p95 0.738 ms (median of three runs) | p50 0.747 ms, p95 1.082 ms (median of three runs). Plan 5 changed no rule: see "How plan 5's numbers were measured" | — |
| A drag frame | `CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` | today's numbers or better | a 60-frame drag of a group of three writes 240 elements (60 x 4: three lines and the group's box); a drag of one line writes 60 | a group of three writes 60 (the group alone, its lines riding in it); one line writes 60. A leaf dragged 60 frames on a free screen lays out its screen's root 60 times and the screen's other four containers 0 times (`StoreChangeBudgetTests.aLeafDragLaysOutOnlyItsDirtyPath`). A 60-frame drag of several lines, a twist and a group's handle each build the store's index at most once (`CanvasDragWorkTests.aGesturesFramesBuildTheIndexOnlyWhenAContainerMoves`) | unchanged: a group of three writes 60 and one line 60 (`CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` asserts both exactly); a leaf dragged 60 frames lays out its screen's root at most 60 times and the other four containers 0 times (`StoreChangeBudgetTests.aLeafDragLaysOutOnlyItsDirtyPath`); a gesture's frames build the index at most once. All pass at 35a3716 | per frame, with the canvas up and both panels open (`DragFrameBenchmarkTests`, 60 frames, the same in each of three runs): a line writes 1 node, builds 1 target and 2 node views (its own and its screen root's); a free group of three writes 1, builds 1 target and 2 node views (the group's and the root's; its lines ride in it); a row's child, lifted, writes 0, builds 0 targets and 1 node view in all 60 frames. The canvas lowers the projection on none of these frames, nor on a screen's (`CanvasNeverLowersTests`). `aDragFrameWritesOnlyWhatItMoves`, `CanvasTargetsWorkTests`, `oneEditRebuildsOnlyTheViewsOnItsPath` and `draggingARowChildWritesNothingUntilTheDrop` pass in the quiet run at 2cef960 | per frame, as plan 4's, the same in each of three runs (`DragFrameBenchmarkTests`): a line writes 1 node, builds 1 target and 2 node views; a free group of three writes 1, builds 1 target and 2 node views; a row's child, lifted, writes 0, builds 0 targets and 1 node view in all 60 frames. The decline check plan 5 runs after every change, timed on each frame's change: a line p50 21.2 µs, p95 24.2 µs; the group p50 18.2 µs, p95 19.2 µs; with the board's row and group made the pass's, so that it walks what they hold, a line 54.5 and 63.6 µs, the group 50.5 and 53.1 µs (medians of three runs): under 0.4% of a 16 ms frame. The lifted row child changes nothing until it is dropped, so no check runs | — |
| Streaming generation | ids of unaffected nodes are stable across updates; one commit per update; layout off the main actor | 100% stable | not measured in this baseline | not measured: plan 3 streams generation through the tree | 100% stable: every id outlives the updates after it, one commit per update, and no layout on the main actor (`GenerationThroughTheReconcilerTests`: `everyIDOutlivesTheUpdatesAfterIt`, `eachUpdateIsOneCommitLaidOutOffTheMainActor`), passing again in plan 3's quiet runs at 35a3716 | not measured again: plan 4 changed no generation path; `GenerationThroughTheReconcilerTests` pass at 2cef960 | not measured again: plan 5 changed no generation path; `GenerationThroughTheReconcilerTests` pass in the full suite | — |
| Generation tokens and time to first content | `ScreenBenchmarkHarness` on macOS | recorded, and the hosted default chosen from them | not measured in this baseline | not measured: plan 3 builds the harness on the tree | On-device, the outline at plan 3's final wording (round 4, `run.sh outline 3`, 24 screens, quiet): first content p50 1049 ms, p95 1127 ms; completion p50 1891 ms, p95 2461 ms. Round 5, the same wording read with every number in a generated outline's looks passed over (Task 13, one run, quiet): first content p50 1041 ms, p95 1211 ms; completion p50 1930 ms, p95 2713 ms. Round 2's wording, before review's fixes, over 72 screens: first content p50 1041 ms, p95 1225 ms; completion p50 1936 ms, p95 2598 ms. The on-device model reports no tokens. LM Studio's runs are smoke only (`screen-prompt.md`) | not measured: plan 4 changed no prompt or generation path | not measured: plan 5 changed no prompt or generation path (`SketchHintTests` pass unchanged) | — |
| One change through the store on a 100-node screen, on the tree | `StoreChangeBudgetTests.aStoreChangeOnAHundredNodeScreenIsWithinBudget` (always on), 50 runs each. On a column of 25 rows: a body resized, a text edited, a text added to a row. On the same rows on a free root: row 12 moved whole (since the fix wave; see below). Each change alone, and with the next read of the screens, which lowers the tree again; the budget holds the change with the read | p95 under 16 ms | not measurable on main (it needs the tree) | resize p50 0.874 ms, p95 0.966 ms; text p50 0.912 ms, p95 1.012 ms; add p50 0.791 ms, p95 0.881 ms (median of three runs, the change alone). The move measured then, p50 0.161 ms, p95 0.196 ms, timed nothing: see "The budget's move" below | move (a row on a free root) p50 0.619 ms, p95 0.662 ms; resize p50 0.597 ms, p95 0.698 ms; text p50 0.717 ms, p95 0.765 ms; add p50 0.799 ms, p95 0.919 ms (median of three runs, the change alone). With the next read, which the budget holds: move p95 0.925 ms, resize 0.958 ms, text 1.033 ms, add 1.178 ms, 13 times under the budget | move (a row on a free root) p50 0.638 ms, p95 0.716 ms; resize p50 0.625 ms, p95 0.660 ms; text p50 0.754 ms, p95 0.798 ms; add p50 0.843 ms, p95 0.895 ms (median of three runs, the change alone). With the next read: move p95 0.971 ms, resize 0.880 ms, text 1.014 ms, add 1.120 ms, 14 times under the budget | move (a row on a free root) p50 0.738 ms, p95 1.070 ms; resize p50 0.670 ms, p95 0.714 ms; text p50 0.797 ms, p95 0.840 ms; add p50 0.909 ms, p95 0.959 ms (median of three runs, the change alone). With the next read: move p95 1.389 ms, resize 0.946 ms, text 1.062 ms, add 1.197 ms, 11 times under the budget | — |
| Canvas workout | `CanvasBenchmarkUITests.testCanvasWorkout`, Release, 5 iterations a run, median of 3 runs | no worse than baseline by more than 5% | CPU time 4.479 s; peak physical memory 84.65 MB; clock 30.233 s (see below) | CPU time 4.777 s; peak physical memory 84.79 MB; clock 30.437 s. CPU time is 6.7% over the Before column, and 0.4% over main measured again in the same hour on the same simulator (4.757 s): see below | CPU time 4.866 s; peak physical memory 84.59 MB; clock 30.504 s (median of three runs). 0.5% over main measured again in the same hour, interleaved with it (4.842 s), retiring the same instructions (25.56 G against 25.50 G); 8.6% over the Before column, where main is now 8.1% over it: see below | CPU time 4.778 s; peak physical memory 75.81 MB; clock 30.435 s (median of three runs). 0.4% under main measured again in the same hour, interleaved with it (4.798 s), retiring 1.1% more instructions (25.64 G against 25.37 G); peak memory equal to main's, both about 9 MB under plan 3's hour: see below | not measured: plan 5's measurements are the sketch path's; plan 6 measures the workout against main in the same hour | — |

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
`{ $0.text += "a" }`, and one text added with `setElements([text], on:)` then deleted,
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
  on the branch writes through the projection, runs the tree's rules and compares the tree. The next read lowers the
  tree again once; that read wasn't in these numbers, and is timed since the fix wave (below). It is still about 35
  times under the 16 ms budget.
- The rules row's Before figure is plan 1's, taken at 130a4f1 in another session. The workout below shows the cores'
  clock moving between sessions (about 3.47 GHz on 2026-11-23, 2.86 GHz here), so the change from 0.957 to 0.646 ms
  can't be credited to the code.
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

The Before column is therefore no longer a valid comparator for CPU time. For the "After plan 6" column, measure main
again in the same hour, interleave the two (branch, main, branch, main) and record the order, and compare instructions
retired first.

Against the Before column the branch's CPU time is 6.7% higher, over the 5% budget. Against main measured again in
the same hour it is 0.4% higher, within it. Main itself now takes 6.2% more CPU time than it did on 2026-11-23 for
the same instructions (25.56 G against 25.53 G) in 12.5% fewer cycles: the cores ran at about 2.86 GHz on average
against 3.47 GHz then. So the difference from the Before column is the machine, not the code: the branch retires the
same instructions as main (25.53 G against 25.56 G), and its peak memory and clock are within 1% of main's.

## The budget's move, and the next read (plan 2's fix wave)

Plan 2's final review found that the always-on budget's "move" timed nothing. It moved row 12's text, which sits in a
row under a column root; a position written to a column root's child is laid back by it (My call 20), so the write drops
the origin before anything is written. The tree came out equal, nothing was laid out, and nothing was laid back: its
0.161 ms is the cost of a change that changes nothing. The env-gated `StoreChangeBenchmarkTests` was never affected: its
screen's root is free, and its move writes.

The budget now moves row 12 whole on the same 25 rows on a free root, a point to the right each run, and checks that the
row moved 50 points and what it holds rode in it. Both benchmarks also time the next read of the screens after each
change, which lowers the tree again: a `+read` BENCH line beside each change's own. The budget holds the change with the
read under 16 ms.

Measured on feature/semantic-tree in the fix wave (2026-11-24, Xcode 27.2, Debug), three runs each, median shown. These
ran in the "Layer iPad Pro 11 (semantic-tree)" simulator, not st2-lane-c's, at 1-minute loads of 40 to 170 with other
lanes building: the machine wasn't quiet (F14), so they show what the read adds and that the budget holds, and are not
comparable with the columns above. Plan 6's After column measures both, quiet, in st2-lane-c's simulator.

| Benchmark | Change | Alone p50 / p95 ms | With the next read p50 / p95 ms |
|---|---|---|---|
| Store (`StoreChangeBenchmarkTests`) | move | 0.272 / 0.287 | 0.449 / 0.468 |
| | resize | 0.276 / 0.290 | 0.451 / 0.471 |
| | text | 0.267 / 0.288 | 0.437 / 0.473 |
| | add (and delete) | 0.560 / 0.576 | 0.733 / 0.752 |
| Tree (`StoreChangeBudgetTests`) | move (a row on a free root) | 0.590 / 0.626 | 0.814 / 0.856 |
| | resize | 0.627 / 0.664 | 0.852 / 0.893 |
| | text | 0.753 / 0.807 | 0.976 / 1.036 |
| | add | 0.849 / 0.903 | 1.079 / 1.150 |

The next read adds about 0.17 ms to a change in the store benchmark, and about 0.22 ms in the tree's, where a screen holds
25 rows as well as 100 things. Every change with its read is still over 13 times under the 16 ms budget.

## How plan 3's numbers were measured

On st3/lane-a 35a3716, ScreenBlueprint removed (2026-11-24, Xcode 27.2), in the same simulator, "Layer iPad Pro 11
(st2-lane-c)", UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47, with the commands above. Lane A was the only lane running; no
other `xcodebuild` ran during any measurement, and the 1-minute load was sampled every 20 seconds through each run.

- The unit benchmarks ran in Debug from lane A's worktree and DerivedData, three times each: `StoreChangeBenchmarkTests`
  alone, then `TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick()`, `StoreChangeBudgetTests` and
  `GenerationThroughTheReconcilerTests` together (every test passed). The first set started each run once the load was
  at most 20, which was right after the run before, at 15.5 to 19.8. The set was run again from loads under 10 (5.1 to
  8.9); those are the column's figures. The two sets' p50s agree within 5%; the busier set's p95 tails were longer,
  most in the tree's move (0.838 ms against 0.662).
  - Store, the change alone, p50 / p95 ms per run: move 0.287 / 0.280 / 0.279, 0.299 / 0.301 / 0.297; resize 0.290 /
    0.287 / 0.285, 0.295 / 0.307 / 0.312; text 0.280 / 0.275 / 0.271, 0.300 / 0.324 / 0.317; add 0.570 / 0.550 / 0.559,
    0.600 / 0.657 / 0.609.
  - Store with the next read, medians: move 0.454 / 0.477, resize 0.465 / 0.483, text 0.440 / 0.512, add 0.730 / 0.791.
  - Rules p50 0.633 / 0.638 / 0.632 ms, p95 0.715 / 0.736 / 0.719.
  - On the tree, the change alone, p50 / p95 ms per run: move 0.619 / 0.632 / 0.608, 0.682 / 0.662 / 0.659; resize
    0.598 / 0.597 / 0.587, 0.698 / 0.726 / 0.679; text 0.717 / 0.724 / 0.709, 0.765 / 0.817 / 0.742; add 0.799 / 0.803 /
    0.797, 0.919 / 0.878 / 1.004.
  - On the tree with the next read, medians: move 0.863 / 0.925, resize 0.823 / 0.958, text 0.940 / 1.033, add 1.028 /
    1.178.
- Plan 3 changed no edit's path: a change through the store costs what it did after plan 2's fix wave (move 0.280 ms
  against 0.272 ms then, measured busy), well under the "After plan 2" column's 0.433 ms, which was before the fix
  wave. The tree's figures are within 10% of the fix wave's.

## Canvas workout after plan 3, and main again in the same hour

The branch at 35a3716 and main at 8d00fc7, each built in Release from a temporary worktree (DerivedData
`Layer-t13-branch-release` and `Layer-t13-main-release`) with `LayerTests` taken out of the scheme and the Layer test plan
there only, and run interleaved from 10:38 to 11:06: branch 1, main 1, branch 2, main 2, branch 3, main 3, branch 4. The
app was uninstalled before every run, and each run started once the 1-minute load was at most 10 (the first pair, at most 20).
Branch 1 was discarded: its load reached 22.4 as it began. Every kept run stayed between 5.3 and 9.7.

| Run | CPU time s | Peak physical MB | Clock s | CPU instructions G | CPU cycles G |
|---|---|---|---|---|---|
| Branch 2 | 4.893 (7.3%) | 84.35 (0.57%) | 30.512 (6.6%) | 25.37 (3.5%) | 13.30 (5.7%) |
| Branch 3 | 4.859 (7.1%) | 84.82 (0.67%) | 30.492 (6.6%) | 25.56 (3.8%) | 13.31 (5.9%) |
| Branch 4 | 4.866 (8.2%) | 84.59 (0.59%) | 30.504 (6.6%) | 25.63 (4.1%) | 13.34 (6.3%) |
| **Branch median** | **4.866** | **84.59** | **30.504** | **25.56** | **13.31** |
| Main 1 | 4.859 (7.1%) | 84.78 (0.52%) | 30.536 (6.7%) | 25.50 (3.8%) | 13.31 (6.0%) |
| Main 2 | 4.842 (7.0%) | 85.02 (0.56%) | 30.507 (6.7%) | 25.54 (3.9%) | 13.25 (6.1%) |
| Main 3 | 4.839 (7.0%) | 84.62 (0.61%) | 30.470 (6.6%) | 25.45 (3.8%) | 13.18 (6.2%) |
| **Main median, again** | **4.842** | **84.78** | **30.507** | **25.50** | **13.25** |
| Discarded: branch 1 | 4.832 | 84.09 | 30.350 | 25.56 | 13.51 |

Against main in the same hour the branch takes 0.5% more CPU time, retires 0.2% more instructions in 0.5% more cycles,
and its peak memory and clock are within 0.2%: within the 5% budget. Against the Before column it is 8.6% over in CPU
time, and main is 8.1% over it now; against plan 2's column the branch is 1.9% over and main 1.8% over plan 2's own
measure of it again. As in plan 2, the difference from the earlier columns is the machine, not the code.

## How plan 4's numbers were measured

On feature/semantic-tree 2cef960 (2026-11-25, Xcode 27.2), in the same simulator, "Layer iPad Pro 11 (st2-lane-c)",
UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47, with the commands above, from 02:08 to 02:59.

- Machine quiet: before every run a script checked with `pgrep` that no other `xcodebuild` was running and waited until
  the 1-minute load was at most 10; the load and the number of `xcodebuild` processes were sampled every 20 seconds
  through every run. No other `xcodebuild` ran during any kept run. Each run's own `xcodebuild` (the build check, the
  install and launch, and for the workout the screen recording) raised the 1-minute load in its first minute: the unit
  runs to between 16 and 47, the workout runs to between 29 and 82, after which it fell back to 6 to 10. The store
  benchmark's first run is discarded: another lane's `xcodebuild` started during it (load 92.9); it was run again as
  run 4. Its figures agreed with the kept runs to within 3%.
- The unit benchmarks ran in Debug from lane A's worktree and DerivedData, three times each: `StoreChangeBenchmarkTests`
  alone; `TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick()` with `StoreChangeBudgetTests`; and
  `DragFrameBenchmarkTests` alone (new in plan 4, gated as the store benchmark is). Every test passed in every run.
  - Store, the change alone, p50 / p95 ms per run (2, 3, 4): move 0.289 / 0.282 / 0.297, 0.304 / 0.314 / 0.307; resize
    0.287 / 0.286 / 0.296, 0.296 / 0.298 / 0.302; text 0.284 / 0.284 / 0.291, 0.288 / 0.294 / 0.301; add 0.582 / 0.576 /
    0.588, 0.596 / 0.618 / 0.603.
  - Store with the next read, medians: move 0.463 / 0.489, resize 0.459 / 0.479, text 0.457 / 0.470, add 0.755 / 0.783.
  - Rules p50 0.646 / 0.712 / 0.661 ms, p95 0.716 / 0.973 / 0.738.
  - On the tree, the change alone, p50 / p95 ms per run: move 0.612 / 0.638 / 0.648, 0.662 / 0.918 / 0.716; resize
    0.609 / 0.632 / 0.625, 0.640 / 0.660 / 0.693; text 0.739 / 0.762 / 0.754, 0.773 / 0.798 / 0.798; add 0.802 / 0.843 /
    0.854, 0.860 / 0.895 / 0.934.
  - On the tree with the next read, medians: move 0.872 / 0.971, resize 0.841 / 0.880, text 0.972 / 1.014, add 1.064 /
    1.120.
  - A drag frame, with `CanvasScreen` shown and the Layers and Format panels open, the targets and node views summed
    over the board's own ids and the writes read from the process-wide `ListWork.elementsWritten`, which only this
    benchmark adds to as it runs alone, the same in all three runs: `BENCH drag line frames=60 writes=60 targets=60 nodeViews=120`, `BENCH drag
    group frames=60 writes=60 targets=60 nodeViews=120`, `BENCH drag rowChild frames=60 writes=0 targets=0 nodeViews=1`.
  - The counter tests, run once after them (`HostedWindowSuites/NodeViewWorkTests/oneEditRebuildsOnlyTheViewsOnItsPath()`,
    `CanvasDragWorkTests`, `HostedWindowSuites/CanvasTargetsWorkTests`,
    `LayoutDragTests/draggingARowChildWritesNothingUntilTheDrop()`): `Test run with 13 tests in 5 suites passed`.
- Plan 4 moved the canvas and the panels onto the tree and changed no edit's path: a change through the store costs
  what it did after plan 3 (move 0.289 ms against 0.280 ms), and the tree's figures are within 6% of plan 3's at p50.
  The slowest change with its read is 14 times under 16 ms.

## Canvas workout after plan 4, and main again in the same hour

The branch at 2cef960 and main at 8d00fc7, each built in Release from a temporary worktree (DerivedData
`Layer-semantic-tree-release` and `Layer-t12-main-release`) with `LayerTests` taken out of the scheme and the Layer test
plan there only, and run interleaved from 02:34 to 02:58: branch 1, main 1, branch 2, main 2, branch 3, main 3. The app
was uninstalled before every run, and each run started once no other `xcodebuild` ran and the 1-minute load was at most
10. Each run's own launch raised the load in its first minute (to 43, 43, 82, 51, 30 and 47 in that order), and it fell
back to 6 to 9 for the rest of the run.

| Run | CPU time s | Peak physical MB | Clock s | CPU instructions G | CPU cycles G |
|---|---|---|---|---|---|
| Branch 1 | 4.800 (7.2%) | 76.03 (0.75%) | 30.455 (6.7%) | 25.66 (3.6%) | 13.65 (6.7%) |
| Branch 2 | 4.739 (6.1%) | 75.81 (0.66%) | 30.392 (6.4%) | 25.43 (3.8%) | 13.59 (6.6%) |
| Branch 3 | 4.778 (7.2%) | 75.56 (0.53%) | 30.435 (6.7%) | 25.64 (4.0%) | 13.60 (6.6%) |
| **Branch median** | **4.778** | **75.81** | **30.435** | **25.64** | **13.60** |
| Main 1 | 4.777 (8.1%) | 75.33 (0.56%) | 30.460 (6.8%) | 25.36 (4.0%) | 13.46 (5.6%) |
| Main 2 | 4.824 (7.8%) | 75.87 (0.62%) | 30.400 (6.7%) | 25.37 (4.2%) | 13.42 (7.2%) |
| Main 3 | 4.798 (7.3%) | 75.81 (0.65%) | 30.332 (6.6%) | 25.40 (4.1%) | 13.69 (8.1%) |
| **Main median, again** | **4.798** | **75.81** | **30.400** | **25.37** | **13.46** |

Against main in the same hour the branch takes 0.4% less CPU time, retires 1.1% more instructions in 1.0% more cycles,
and its peak memory is the same and its clock 0.1% longer: within the 5% budget. Without branch run 2, whose launch
raised the load most, the branch's CPU time is 4.789 s, 0.2% under main's. Against plan 3's column (4.866 s) the branch
is 1.8% under, and main 0.9% under its own measure in plan 3's hour (4.842 s); against the Before column (4.479 s) the
branch is 6.7% over and main 7.1% over. Peak memory is about 9 MB lower than in plan 3's hour for main and the branch
alike (75.8 MB against 84.6 MB and 84.8 MB), so it is the simulator or the machine, not the code.

## How plan 5's numbers were measured

The app as it is at feature/semantic-tree f36ab30, with Task 12's tests (2026-11-25, Xcode 27.2), in the same simulator,
"Layer iPad Pro 11 (st2-lane-c)", UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47, from 06:23 to 07:15. Task 12 changed no app
code but comments.

- Machine quiet: the other lanes were asked to pause new builds for the window. The tests were built once before it
  (`build-for-testing`, lane A's DerivedData), and each run was a `test-without-building` with
  `TEST_RUNNER_LAYER_BENCHMARK=1`. Before every run a script checked with `pgrep` that no other `xcodebuild` was running
  and waited until the 1-minute load was at most 10; the load and the number of `xcodebuild` processes were sampled every
  20 seconds through the window. No other `xcodebuild` ran during any run: another lane's build ran from 06:28 to 06:35,
  between two runs, and the next run waited for the load to fall back under 10. Each run's own `xcodebuild` raised the load
  in its first minute, to between 23 and 73.
- Three rounds of `SketchConversionBudgetTests/aReadingLandsWithinBudget()`, `SketchBenchmarkTests/printsTheFullBenchmarkReport()`,
  `TidyTests/tidyingSixHundredThingsIsQuick()` and `DragFrameBenchmarkTests`, each alone; then the macOS tidy timing
  (below, under the structure pass); then three rounds of `StoreChangeBenchmarkTests` alone and
  `TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick()` with `StoreChangeBudgetTests`. Every test passed in every run, and
  each budget test at its first attempt.
  - The conversion (the reading, the landing and the pass), p50 / p95 ms per run: 1.567 / 1.568 / 1.538, 2.244 / 2.131 /
    2.214. The pass alone: p50 0.005 in each, p95 0.162 / 0.165 / 0.165.
  - The rules' reading over the 156 fixtures, p50 / p95 ms per run: 0.0018 / 0.0019 / 0.0019, 0.0147 / 0.0142 / 0.0147.
    87.8% in each.
  - Store, the change alone, p50 / p95 ms per run: move 0.335 / 0.327 / 0.347, 0.357 / 0.333 / 0.356; resize 0.338 /
    0.332 / 0.347, 0.353 / 0.341 / 0.354; text 0.326 / 0.330 / 0.342, 0.335 / 0.339 / 0.345; add 0.631 / 0.637 / 0.649,
    0.646 / 0.668 / 0.662.
  - Store with the next read, medians: move 0.510 / 0.533, resize 0.510 / 0.530, text 0.501 / 0.517, add 0.811 / 0.839.
  - Rules p50 0.747 / 0.764 / 0.731 ms, p95 1.082 / 1.261 / 1.011.
  - On the tree, the change alone, p50 / p95 ms per run: move 0.735 / 0.754 / 0.738, 1.050 / 1.070 / 1.077; resize
    0.667 / 0.672 / 0.670, 0.714 / 0.694 / 0.720; text 0.797 / 0.839 / 0.777, 0.828 / 0.928 / 0.840; add 0.897 / 0.909 /
    0.928, 0.945 / 0.959 / 1.024.
  - On the tree with the next read, medians: move 0.986 / 1.389, resize 0.889 / 0.946, text 1.020 / 1.062, add 1.135 /
    1.197.
  - A drag frame: the counts were plan 4's in all three runs. The decline check, p50 / p95 µs per run: line 21.2 / 21.4 /
    21.2, 24.2 / 26.0 / 23.9; group 18.2 / 17.5 / 18.2, 20.8 / 19.2 / 19.0; made the pass's, line 54.5 / 55.7 / 54.2,
    60.0 / 63.9 / 63.6, and group 50.9 / 49.5 / 50.5, 53.1 / 53.7 / 51.8.
  - Voice's tidy of 600 things (`DesignStore.tidy`, the pass and building what it is sure of, Debug): 169.7 / 167.4 /
    166.8 ms, 51 structures each time.
- What the conversion times (`SketchConversionBudgetTests`): what the app's conversion does once the pen has rested,
  without its deliberate pauses (the 900 ms rest and the 750 ms re-trace). That is the sketch observed from its strokes,
  the request made with what the tree says is on the screen, the rules' reading (with its close-call check and its
  score), and then, as one step, `addSketched` and `structurePass(over:)`. PencilKit's handwriting recogniser isn't in it;
  `printsTheFullBenchmarkReport` times it apart. Each reading is undone, untimed, so every one lands on the same screen.
  The 116 readings are the 124 fixtures placed on a screen, less the 8 scratch-outs.
- The budget's screen is 25 rows, each a text, a body, a toggle and a divider, each of the 100 remembering its sketch.
  The rows have no sketch: they are the person's, which the pass never takes. So a sketch whose centre is on a row lands
  in it, and no pass runs, since a row isn't free; one below or beside them lands on the root, where the pass finds
  nothing it may take but the new thing. That is why the pass is mostly its fixed cost here (p50 5 µs). The rows have
  to be the person's for `thePassLooksOnlyAtTheReceivingContainer`'s bound to hold: the pass's neighbourhood grows from
  the new thing through every arrangeable thing within 48 pt of one already in it, and rows the pass had made, 30 pt
  apart, would bring in all 25.
- Plan 5 changed no rule: `TreeRules`, `LayoutEngine`, `TreeIndex` and `LayerNode` are as plan 4 left them. In a
  change's path it added one thing: after every forward change the store runs the decline check (Task 9). The store's
  changes cost 0.046 to 0.055 ms more at p50 than in plan 4's column, and the tree's 0.043 to 0.100 ms more. The drag
  benchmark times the check at about 20 µs on its screen of 45 things, and the check walks every node of a changed
  screen, so on these screens of 100 things it is most of the rise. The rules' benchmark, which runs no store code, is
  13% over plan 4's at p50 (0.747 ms against 0.661 ms), so the machine is part of it too. Every change with its read is
  still at least 11 times under 16 ms.

## Structure pass (plan 5, Task 8)

The 32 `LayerTests/Fixtures/structure-*.json` fixtures are drawn in the sketch corpus's style (`SketchSamples` strokes,
seeded jitter of 1.5 for jittered and 4.5 for noisy, regenerated byte for byte by `run.sh generate`, which leaves the 156
sketch fixtures as they were). Each is things already on an iPhone screen and one batch of sketches. Every sketch is read
by `RuleInterpreter`, placed with `SketchedNode` on a free root, and then `StructureInference.infer` runs over the batch
(over a new card's inside, for a card). The sketch corpus's loader skips `structure-`.

| Group | Fixtures | What each should become |
|---|---|---|
| Rows | 8: toggle beside a label, two half-width images, three avatars; 3 clean, 3 jittered, 2 noisy (toggle, images) | a row, applied |
| Columns | 6: three wide boxes as text fields, four stacked-line bodies; 2 clean, 2 jittered, 2 noisy | a column, applied |
| Grids | 6: 2 × 2 and 2 × 3 half-width images; 2 clean, 2 jittered, 2 noisy | a grid, applied |
| Cards | 4: an outline round two texts (clean, jittered), round three (clean, noisy) | a card; its inside none for two, a column applied for three |
| Near misses | 8: a title 120 pt above a button, two images 40 apart, heights 2.5 times apart (an image and an avatar), a locked divider between texts, an L of three images, a column edge 6 pt off, an outline round a title and a body with a third text half under its edge (a card of the two, the text left out), a lone text | none (the card's inside none) |

A clean or jittered fixture must be its structure with its decision; a near miss must give none; a noisy fixture may be
its structure or none, never another (`isAsExpected`). The fixtures went in first and `StructureFixtureTests` was red
before any of them was generated.

Controls are tests in `StructureFixtureTests`: each near miss with only its one cause changed back must group (the image's
height 150 to 70 beside the avatar, the divider unlocked, the column's edge 6 pt off made 0, the gap 40 made 20), so that
none is for the reason it names. The half-over outline reads as a card that takes the title and the body and leaves the
text; with the text wholly inside it takes all three.

Two things the layout does to a sketch shaped the fixtures: `ElementLayout.sketched` places a sketched title or body after
a neighbour on its left at the gutter, and lines a box's leading edge up with a neighbour's within 8 pt. So "two texts 40
apart" is two images, and the column edge 6 pt off is an existing thing 6 pt off the one it would line up with.

**Tuning.** None: every fixture came out as it should the first time the fixtures were fixed. `StructureConventions.reach`
and `SketchConventions`' card scores are as before, and `CardReadingTests` is untouched.

Result, macOS harness and the simulator both: `structure: 32 fixtures, 32 as expected, near misses grouped 0`. Found
structures: 8 rows, 5 columns, 6 grids and 4 cards (2 with a column applied inside), none 9 (the 8 near misses, and the
noisy column fixture whose third field read as a button).

**The pass's time** over one batch, which is the whole of `StructureInference.infer` for it, measured once the machine was
quiet (no other `xcodebuild` and no other lane running; the 1-minute load was 3.5 when the runs began, at 3:07 and 3:10 on
2026-11-25, at the commit this section was written with):

| Where | p50 | p95 |
|---|---|---|
| macOS harness, `run.sh structure` (Release, `-O`), three runs | 0.021 to 0.028 ms | 0.089 to 0.114 ms |
| "Layer iPad Pro 11 (st2-lane-c)", `StructureFixtureTests.printsTheStructureReport` (Debug), one run | 0.128 ms | 0.442 ms |

Both are far under the 100 ms budget: a batch's neighbourhood is a handful of nodes.

**Voice's tidy over a large screen** (`mode: .tidy`, every arrangeable child new, so the neighbourhood is the whole
container), timed once with a throwaway harness run (Release, `-O`, the same quiet machine, medians of five runs): the nodes
are texts and images 120 × 80 on a 140 × 100 grid, each off its place by up to 3 pt.

| Children | Decisions | Time |
|---|---|---|
| 9 | 4 | 0.2 ms |
| 30 | 7 | 0.7 ms |
| 100 | 11 | 58 ms |
| 200 | 23 | 274 ms |
| 600 | 46 | 32.6 s |

The cost grows much faster than the number of children: from 200 to 600 children it grows 3 times and the time 120 times. A
tidy of a hundred things is quick; one of several hundred in a single container is not. This is the grid search's growth
(Task 3 and Task 6), recorded here for Task 10, which runs tidy; it is not changed in Task 8.

**Since Task 10**, which bounded it, measured again in Task 12 on the quiet machine (see "How plan 5's numbers were
measured"), with a throwaway harness built as `run.sh` builds the sketch harness (Release, `-O`), medians of five runs. The
nodes are the first n of `TidyTests.tidyingSixHundredThingsIsQuick`'s lattice: rows of 24 down the 140 × 100 grid, texts
and images in turn, each off its place by −3 to 3 pt. At 600 that is Task 8's case (as `TidyTests` records it); Task 8 didn't
record how it laid out the smaller counts, so below 600 the decisions aren't comparable with its table.

| Children | Decisions | Time (runs) |
|---|---|---|
| 9 | 1 | 0.15 ms (2.08, 0.18, 0.15, 0.14, 0.10) |
| 30 | 2 | 0.94 ms (0.94, 1.09, 0.96, 0.90, 0.88) |
| 100 | 8 | 3.6 ms (4.43, 3.87, 3.57, 3.35, 3.22) |
| 200 | 18 | 6.1 ms (6.96, 6.46, 6.08, 5.75, 5.47) |
| 600 | 51 | 14.5 ms (16.80, 15.50, 14.48, 14.44, 14.50) |

From 200 to 600 children the time now grows 2.4 times, and 600 take 14.5 ms where they took 32.6 s. Task 10 searches grids
one band of at most 64 things at a time (`StructureConventions.gridSearchedTogether`), so the 600-thing lattice makes more,
smaller grids than one search over all of it did (51 decisions where Task 8 counted 46). In the simulator, unoptimised, the whole of voice's tidy of those 600
things (`DesignStore.tidy`: the pass and building the 51 structures it is sure of) takes 166.8 to 169.7 ms over three runs,
under `tidyingSixHundredThingsIsQuick`'s 300 ms.
