# Performance review fixes (branch perf/review-fixes, from main 100e54c)

One commit per fix. Tests are in LayerTests/PerformanceFixTests.swift (hosted ones under HostedWindowSuites). Each counter is DEBUG-only. "Before" is what the test measured on the unfixed code (RED seen for every item); where the message did not print a number I say "derived".

1. Turn session / selected things (finding 1). `DesignStore.contentVersion` (reads `content`, returns the change count); `AppModel.selectedThings` and the formed `severalTurn` are kept per (selection, version). A held session still goes through `matches(store)`. Counter `CanvasWork.turnSessionsFormed`: 50 frames of reads of shape, knob, turn and canTurn on a selected group: about 100 before (derived: 2 per frame), 1 after; several things: about 50 before (derived), 1 after. A change to the design forms exactly one more, and the shape equals `canvasShape` of the group.
2. ShareMenu (finding 2). `SharedSwiftUICode` (Transferable, `ProxyRepresentation(exporting: \.source)`) holds the screen, all screens and the settings and generates on export. The preview name still uses `fileName(for:among:)` (cheap, O(screens)). Counter `CodeWork.generated`, hosted ShareMenu over 30 store changes: 30 before, 0 after. Test that the exported data equals `Data(SwiftUICodeGenerator.code(...).utf8)`, and that a String exports the same way (so the output is byte for byte the same as `ShareLink(item: String)`).
3. `isTarget` (finding 3). `groupsWithSomethingShowing()`: one pass, builds one id dictionary, marks the group chain above each showing non-group member. Counter `GroupWork.leafWalks` (in `leaves(of:)`): 4 for 4 groups before, 0 after. A reference implementation of the old rule in the test is compared on nested, hidden, emptied and entered groups, and per host: equal.
4. PencilBridge hover recogniser (finding 9, first half). Attached only while `scrubber.wantsSqueeze` (a ruler is up or the pencil is over a field a squeeze would scrub), read in `updateUIView`. Window hover recognisers added by the bridge: 1 idle before, 0 after; 1 with a ruler up or a field hovered. The `Color.black.opacity(0.001)` layer in `WindowSqueeze` was not touched (it is already gated by `Squeezable`).
5. Zoom ruler pieces (finding 8). The marks set is a static; `ZoomStops.hover(_:frame:target:)` makes and writes the target only when the hovered field is not already the zoom at that frame. Counters `ZoomWork.targetsMade`: 100 for 100 moves before, 1 after; `majorSetsBuilt`: 50 for 50 rulers before, 0 after (built once).
6. Delete (finding 15). `tellTheReadingLogOfDeleted` starts one Task with the whole id set; `SketchReadingLog.noteDeleted(_ ids:)` added. `CanvasWork.readingLogTasks`: 5 for a group of 5 before, 1 after. A log test checks a set of ids marks each deleted reading.
7. Grid tile (finding 11): skipped. The tile's pixel size is the grid gap (`origin` is the offset modulo that gap, and the comment says the tile repeats exactly), so quantising it changes the mark spacing, and scaling a quantised tile through `.tiledImage(scale:)` resamples the dots by up to the step. The `Canvas` closure also has no notion of a settled zoom to switch back to an exact tile. That is a design change (render once at settled scale, scale live), not a small one.

## Results
- Unit (CI plan, 1,297 tests): all pass.
- UI (Layer plan, LayerUITests, erased simulator): 41 passed; only testMagicPenSketchesBecomeADesignWithCode and testTheReferenceDesignFitsTheCanvas failed (the two expected).
- Release build (generic iOS): succeeded; only the old MicrophoneTap InterruptionType deprecation. Release folder and result bundles deleted.

## Concerns
- The hosted counter tests (share menu, bridge) read global counters while other suites run alongside across awaits; a suite that writes code during the share test's 30 frames would fail it. Passed in the full run; not run in a loop.
- Items 1 and 3 keep results per design version; `contentVersion` moves only when `content` actually changes (`content != oldValue`), the same test the store already uses.

## Review fixes
1. `CodeWork` now counts per screen id under an `OSAllocatedUnfairLock` (`CodeWork.generated(for:)`); the share test asserts on its own board's screen only.
2. `groupsWithSomethingShowing()` checks for a group item first and builds the id dictionary only after, so an ungrouped design costs one scan.
3. New counter `CanvasWork.thingsListed` (in `DesignStore.things(in:)`) and a test: 50 reads of `selectedThings` list once (would be 50 without the memo).
4. New test `theKeptOutlineFollowsUndoLocksHidingAndMembership`: after move, undo, redo, member lock/hide, group lock, member added/removed, and several-thing edits (lock, turn, delete), the kept things, outline and turn are compared with a freshly formed session.
5. PencilBridgeWorkTests polls (20 ms steps, up to 2 s) for the expected recogniser count instead of fixed 150 ms sleeps.
Verified: PerformanceFixTests plus the two hosted suites 5 runs in a row, all green; full CI plan twice (1,299 tests), green. Product code touched besides item 2: DEBUG counters only, so no UI run.
