# Semantic tree: performance baseline and budgets

Spec §13. The "Before" column was measured on main 8d00fc7 (2026-11-23, Xcode 27.2, iOS 27.2 simulator
"Layer iPad Pro 11 (st2-lane-c)", UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47). The "After" columns
are filled when plans 2, 3, 4 and 6 end, with the same simulator and the same commands; plan 3's generation figures come
from `Tools/ScreenBenchmarkHarness` on macOS, where the on-device model runs.

| What | How | Budget | Before (main 8d00fc7) | After plan 2 | After plan 3 | After plan 4 | After plan 6 |
|---|---|---|---|---|---|---|---|
| Reading after the pen rests (rules path, no model) | `SketchBenchmark` timings over the 156 fixtures, plus the conversion including the structure pass | p95 under 100 ms | not measured in this baseline (it needs the tree) | not measured: plan 5 puts the reading on the tree | not measured: plan 5 puts the reading on the tree | not measured: plan 5 puts the reading on the tree | — |
| Layout of one edit on a 100-node screen: the store | `StoreChangeBenchmarkTests`, 50 runs each, `ContinuousClock`: each change alone, and (since the fix wave) with the next read of the screens after it, a `+read` line | p95 under 16 ms in the simulator; checked on the iPad | move p50 0.174 ms, p95 0.183 ms; resize p50 0.175 ms, p95 0.186 ms; text p50 0.175 ms, p95 0.185 ms; add (and delete) p50 0.333 ms, p95 0.353 ms. The change alone: no read was timed | move p50 0.433 ms, p95 0.457 ms; resize p50 0.429 ms, p95 0.464 ms; text p50 0.430 ms, p95 0.450 ms; add (and delete) p50 0.544 ms, p95 0.571 ms (median of three runs). The change alone. About 2.5 times main, and within budget (see below). The next read adds about 0.17 ms (fix wave, below) | move p50 0.280 ms, p95 0.299 ms; resize p50 0.287 ms, p95 0.307 ms; text p50 0.275 ms, p95 0.317 ms; add (and delete) p50 0.559 ms, p95 0.609 ms (median of three runs, the change alone). With the next read: move p95 0.477 ms, resize 0.483 ms, text 0.512 ms, add 0.791 ms. As plan 2's fix wave left it (see "How plan 3's numbers were measured") | move p50 0.289 ms, p95 0.307 ms; resize p50 0.287 ms, p95 0.298 ms; text p50 0.284 ms, p95 0.294 ms; add (and delete) p50 0.582 ms, p95 0.603 ms (median of three runs, the change alone). With the next read: move p95 0.489 ms, resize 0.479 ms, text 0.470 ms, add 0.783 ms. Within 5% of plan 3's: plan 4 changed no edit's path (see "How plan 4's numbers were measured") | — |
| Layout of one edit on a 100-node screen: the rules | plan 1's `TreeRulesTests.oneEditOnAHundredNodeScreenIsQuick` (at 130a4f1, from plan 1's ledger) | p95 under 16 ms | p50 0.957 ms, p95 1.292 ms | p50 0.646 ms, p95 0.820 ms (median of three runs, on this branch) | p50 0.633 ms, p95 0.719 ms (median of three runs) | p50 0.661 ms, p95 0.738 ms (median of three runs) | — |
| A drag frame | `CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` | today's numbers or better | a 60-frame drag of a group of three writes 240 elements (60 x 4: three lines and the group's box); a drag of one line writes 60 | a group of three writes 60 (the group alone, its lines riding in it); one line writes 60. A leaf dragged 60 frames on a free screen lays out its screen's root 60 times and the screen's other four containers 0 times (`StoreChangeBudgetTests.aLeafDragLaysOutOnlyItsDirtyPath`). A 60-frame drag of several lines, a twist and a group's handle each build the store's index at most once (`CanvasDragWorkTests.aGesturesFramesBuildTheIndexOnlyWhenAContainerMoves`) | unchanged: a group of three writes 60 and one line 60 (`CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` asserts both exactly); a leaf dragged 60 frames lays out its screen's root at most 60 times and the other four containers 0 times (`StoreChangeBudgetTests.aLeafDragLaysOutOnlyItsDirtyPath`); a gesture's frames build the index at most once. All pass at 35a3716 | per frame, with the canvas up and both panels open (`DragFrameBenchmarkTests`, 60 frames, the same in each of three runs): a line writes 1 node, builds 1 target and 2 node views (its own and its screen root's); a free group of three writes 1, builds 1 target and 2 node views (the group's and the root's; its lines ride in it); a row's child, lifted, writes 0, builds 0 targets and 1 node view in all 60 frames. The canvas lowers the projection on none of these frames, nor on a screen's (`CanvasNeverLowersTests`). `aDragFrameWritesOnlyWhatItMoves`, `CanvasTargetsWorkTests`, `oneEditRebuildsOnlyTheViewsOnItsPath` and `draggingARowChildWritesNothingUntilTheDrop` pass in the quiet run at 2cef960 | — |
| Streaming generation | ids of unaffected nodes are stable across updates; one commit per update; layout off the main actor | 100% stable | not measured in this baseline | not measured: plan 3 streams generation through the tree | 100% stable: every id outlives the updates after it, one commit per update, and no layout on the main actor (`GenerationThroughTheReconcilerTests`: `everyIDOutlivesTheUpdatesAfterIt`, `eachUpdateIsOneCommitLaidOutOffTheMainActor`), passing again in plan 3's quiet runs at 35a3716 | not measured again: plan 4 changed no generation path; `GenerationThroughTheReconcilerTests` pass at 2cef960 | — |
| Generation tokens and time to first content | `ScreenBenchmarkHarness` on macOS | recorded, and the hosted default chosen from them | not measured in this baseline | not measured: plan 3 builds the harness on the tree | On-device, the outline at plan 3's final wording (round 4, `run.sh outline 3`, 24 screens, quiet): first content p50 1049 ms, p95 1127 ms; completion p50 1891 ms, p95 2461 ms. Round 5, the same wording read with every number in a generated outline's looks passed over (Task 13, one run, quiet): first content p50 1041 ms, p95 1211 ms; completion p50 1930 ms, p95 2713 ms. Round 2's wording, before review's fixes, over 72 screens: first content p50 1041 ms, p95 1225 ms; completion p50 1936 ms, p95 2598 ms. The on-device model reports no tokens. LM Studio's runs are smoke only (`screen-prompt.md`) | not measured: plan 4 changed no prompt or generation path | — |
| One change through the store on a 100-node screen, on the tree | `StoreChangeBudgetTests.aStoreChangeOnAHundredNodeScreenIsWithinBudget` (always on), 50 runs each. On a column of 25 rows: a body resized, a text edited, a text added to a row. On the same rows on a free root: row 12 moved whole (since the fix wave; see below). Each change alone, and with the next read of the screens, which lowers the tree again; the budget holds the change with the read | p95 under 16 ms | not measurable on main (it needs the tree) | resize p50 0.874 ms, p95 0.966 ms; text p50 0.912 ms, p95 1.012 ms; add p50 0.791 ms, p95 0.881 ms (median of three runs, the change alone). The move measured then, p50 0.161 ms, p95 0.196 ms, timed nothing: see "The budget's move" below | move (a row on a free root) p50 0.619 ms, p95 0.662 ms; resize p50 0.597 ms, p95 0.698 ms; text p50 0.717 ms, p95 0.765 ms; add p50 0.799 ms, p95 0.919 ms (median of three runs, the change alone). With the next read, which the budget holds: move p95 0.925 ms, resize 0.958 ms, text 1.033 ms, add 1.178 ms, 13 times under the budget | move (a row on a free root) p50 0.638 ms, p95 0.716 ms; resize p50 0.625 ms, p95 0.660 ms; text p50 0.754 ms, p95 0.798 ms; add p50 0.843 ms, p95 0.895 ms (median of three runs, the change alone). With the next read: move p95 0.971 ms, resize 0.880 ms, text 1.014 ms, add 1.120 ms, 14 times under the budget | — |
| Canvas workout | `CanvasBenchmarkUITests.testCanvasWorkout`, Release, 5 iterations a run, median of 3 runs | no worse than baseline by more than 5% | CPU time 4.479 s; peak physical memory 84.65 MB; clock 30.233 s (see below) | CPU time 4.777 s; peak physical memory 84.79 MB; clock 30.437 s. CPU time is 6.7% over the Before column, and 0.4% over main measured again in the same hour on the same simulator (4.757 s): see below | CPU time 4.866 s; peak physical memory 84.59 MB; clock 30.504 s (median of three runs). 0.5% over main measured again in the same hour, interleaved with it (4.842 s), retiring the same instructions (25.56 G against 25.50 G); 8.6% over the Before column, where main is now 8.1% over it: see below | CPU time 4.778 s; peak physical memory 75.81 MB; clock 30.435 s (median of three runs). 0.4% under main measured again in the same hour, interleaved with it (4.798 s), retiring 1.1% more instructions (25.64 G against 25.37 G); peak memory equal to main's, both about 9 MB under plan 3's hour: see below | — |

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
  - A drag frame, with `CanvasScreen` shown and the Layers and Format panels open, each count summed over the board's
    own ids, the same in all three runs: `BENCH drag line frames=60 writes=60 targets=60 nodeViews=120`, `BENCH drag
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

