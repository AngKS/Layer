# Semantic tree: performance baseline and budgets

Spec §13. The "Before" column was measured on main 8d00fc7 (2026-11-23, Xcode 27.2, iOS 27.2 simulator
"Layer iPad Pro 11 (st2-lane-c)", UDID 19CD922B-1564-4FEF-A86A-4AF37B114B47). The "After" columns
are filled when plan 2 and plan 6 end, with the same simulator and the same commands.

| What | How | Budget | Before (main 8d00fc7) | After plan 2 | After plan 6 |
|---|---|---|---|---|---|
| Reading after the pen rests (rules path, no model) | `SketchBenchmark` timings over the 156 fixtures, plus the conversion including the structure pass | p95 under 100 ms | not measured in this baseline (it needs the tree) | — | — |
| Layout of one edit on a 100-node screen: the store | `StoreChangeBenchmarkTests`, 50 runs each, `ContinuousClock` | p95 under 16 ms in the simulator; checked on the iPad | move p50 0.174 ms, p95 0.183 ms; resize p50 0.175 ms, p95 0.186 ms; text p50 0.175 ms, p95 0.185 ms; add (and delete) p50 0.333 ms, p95 0.353 ms | — | — |
| Layout of one edit on a 100-node screen: the rules | plan 1's `TreeRulesTests.oneEditOnAHundredNodeScreenIsQuick` (at 130a4f1, from plan 1's ledger) | p95 under 16 ms | p50 0.957 ms, p95 1.292 ms | — | — |
| A drag frame | `CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` | today's numbers or better | a 60-frame drag of a group of three writes 240 elements (60 x 4: three lines and the group's box); a drag of one line writes 60 | — | — |
| Streaming generation | ids of unaffected nodes are stable across updates; one commit per update; layout off the main actor | 100% stable | not measured in this baseline | — | — |
| Generation tokens and time to first content | `ScreenBenchmarkHarness` on macOS | recorded, and the hosted default chosen from them | not measured in this baseline | — | — |
| Canvas workout | `CanvasBenchmarkUITests.testCanvasWorkout`, Release, 5 iterations a run, median of 3 runs | no worse than baseline by more than 5% | CPU time 4.479 s; peak physical memory 84.65 MB; clock 30.233 s (see below) | — | — |

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
