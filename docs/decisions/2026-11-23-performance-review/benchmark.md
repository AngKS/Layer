# Canvas benchmark: origin/main 7c9ac79 vs main 100e54c (2026-11-23)

Verdict: no regression. NEW (100e54c) is faster on CPU (about 12% less CPU time, 14% fewer cycles, 17% fewer instructions), uses about 3% less memory, and its clock is about 12% lower. All of that is well outside run-to-run noise (below 1% between runs of the same build on CPU time and memory).

## Method
- `CanvasBenchmarkUITests/testCanvasWorkout`, Release, iPad Pro 11 simulator 30253E2F (iOS 27.2), XCTCPUMetric + XCTMemoryMetric + XCTClockMetric, 5 iterations per run. Each table cell is the mean of the 5 iterations of one `xcodebuild test` run.
- Two detached worktrees (7c9ac79 and 100e54c), separate derived data. Runs alternated base, new, base, new, base, new (3 each). Simulator erased before the first run of each build; app uninstalled before every run.
- Workout file: no change needed. main's file (zoom by the "Zoom" menu: tap "Zoom", tap "200%"/"100%"/"50%"/"100%") already drives both builds, because BASELINE also has a "Zoom" menu button with 25/50/100/200/400 levels (the old file used the "Zoom in"/"Zoom out" step buttons, which NEW no longer has). I copied main's file into the base worktree, so both ran identical test code. All 6 runs passed. The tap-on-selected-deselects change does not matter to the workout (it ends by tapping empty canvas). Nothing committed in the repo (step 4 not needed: main already holds the updated workout).
- Build deviation, applied to both worktrees only: Release cannot compile LayerTests (DEBUG-only symbols, no @testable import), so LayerTests was removed from the scheme build and both test plans inside the worktrees. The app and UI tests are built Release with the same settings in both.

## Every run (mean of 5 iterations)
| Run | CPU time s | CPU cycles Gc | Instr retired Gi | Peak phys MB | Abs phys MB | Clock s |
|---|---|---|---|---|---|---|
| base 1 | 5.44 | 15.53 | 30.92 | 85.4 | 84.0 | 34.7 |
| new 1 | 4.70 | 13.66 | 25.60 | 82.7 | 81.2 | 30.5 |
| base 2 | 5.5 | 15.70 | 30.94 | 87.0 | 85.5 | 34.7 |
| new 2 | 4.9 | 13.37 | 25.40 | 84.7 | 83.1 | 30.5 |
| base 3 | 5.6 | 15.55 | 30.99 | 86.8 | 85.5 | 34.8 |
| new 3 | 4.9 | 13.39 | 25.60 | 84.5 | 83.0 | 30.5 |

## Median per build and change
| Metric | BASE median | NEW median | Change |
|---|---|---|---|
| CPU time | 5.5 s | 4.9 s | -11.7% |
| CPU cycles | 15.55 G | 13.39 G | -13.9% |
| Instructions retired | 30.94 G | 25.60 G | -17.3% |
| Peak physical memory | 86.8 MB | 84.5 MB | -2.6% |
| Absolute physical memory | 85.5 MB | 83.0 MB | -2.9% |
| Clock | 34.7 s | 30.5 s | -12.2% |

Noise: within a build, instructions vary under 0.3% between runs, cycles about 1 to 2%, peak memory about 1.8%; iteration-level RSD inside a run is 4 to 6% for CPU time. The NEW-vs-BASE gap is 3 to 4 times the run-to-run spread on instructions and cycles, and every NEW run beats every BASE run on every metric, so it is real for this workout. Clock is mostly the script's waiting; NEW's 4 s lower clock probably comes from the popover opening faster than the old Menu (not verified).

## Profile (Time Profiler, attached to Layer, first 150 s of one run each; the traced runs are not in the table)
Total sampled main-thread-and-other time: NEW 22.7 s, BASE 23.8 s. App-owned code is almost no self time (NEW 54 ms of 22.7 s); the cost is SwiftUI/AttributeGraph/UIKit/objc called from the app. Top app symbols by time including callees below them (nearest Layer frame to the leaf; `$main` is the run loop and is omitted), ms:

| NEW | ms | BASE | ms |
|---|---|---|---|
| InkCanvas.Coordinator.viewportChanged(by:) | 799 | InkCanvas.Coordinator.viewportChanged(by:) | 495 |
| DocumentCanvasView.layoutSubviews() | 526 | DocumentCanvasView.layoutSubviews() | 415 |
| closure #1 in CanvasGrid.body.getter | 88 | AppModel.withMutation | 89 |
| AppModel.withMutation | 85 | closure #1 in InkCanvas.Coordinator.animate(to:isByUser:) | 86 |
| closure #1 in InkCanvas.Coordinator.animate | 46 | closure #1 in CanvasGrid.body.getter | 64 |
| InkCanvas.Coordinator.refresh() | 41 | InkCanvas.Coordinator.refresh() | 46 |
| SelectionLayer.body.getter | 41 | AppModel.access | 27 |
| SelectionSummary.init() | 25 | PenTracker.withMutation | 23 |
| OnCanvas.body.getter | 13 | SelectionSummary.init() | 23 |
| ZoomControl.body.getter | 8 | OnCanvas.body.getter | 17 |

Leaf time is the same system frames in both (mach_msg2_trap, objc_msgSend, AG::Graph::propagate_dirty, AG::Subgraph::update, dyld header walks).

## What I would look at
- Nothing is urgent. The one visible difference in the traces is `viewportChanged(by:)` (799 vs 495 ms) and `layoutSubviews()` (526 vs 415 ms): more time in the canvas viewport path in NEW's trace, though the trace windows cover different phases of a faster run, so this is an observation, not a finding. They are the largest app-owned costs in both builds and the best place to look for a speed-up (what viewportChanged invalidates on each pan/zoom step, and the SwiftUI updates it triggers through AttributeGraph).
- New work is small in the profile: SelectionLayer.body 41 ms, ZoomControl.body 8 ms.
- The workout has three phone frames and no groups, no rotation and no selection. It does not exercise groups, the Layers panel tree, the zoom scrub, or a large selection; a second workout with a multi-selection and a group would test the new code.
