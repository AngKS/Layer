# Layer performance review, code level (main 100e54c vs origin/main)

Read-only review of `git diff origin/main..main -- Layer` plus the code it touches. Nothing was built, run or profiled: every cost below is an estimate from reading the code (n = elements in the design, S = screens, G = groups, M = things selected). "Sure" is how sure I am of the mechanism; the cost figures are order-of-magnitude for an A17 Pro iPad mini at n of 300 to 1,000 and need a trace to confirm. Hosted counters named below follow the existing `CanvasWork` / `LayersPanelWork` / `ListWork` pattern (DEBUG-only static counters, asserted in a hosted drag or pan).

Legend: **FIX NOW** = small, contained, safe before a push. **PLAN** = worth doing, needs design or tests.

## Status of the earlier audit (reports/iPadOS performance audit of Layer.md)

| Earlier finding | Status on main |
|---|---|
| 1. Shared viewport state read by subtrees every pan/zoom frame | Mostly done. `scrollOffset` and `zoomScale` are tracked apart (AppModel.swift:171-180); `ZoomControl` reads zoom only (StatusChrome.swift:27); `ElementTargets` is built only in Select and follows `settledScale` (SelectionLayer.swift:39, 838); shadows drop mid-zoom (PhoneScreenView.swift:20-21); `GeometryReader` replaced by `onGeometryChange`. Residual: `SelectionLayer`, `RotateKnob`, `HoverOutline` and `OnCanvas` still read the combined `viewport`, so they re-run on every pan frame (finding 7 below). |
| 2. Second live PKCanvasView | Mitigated. `sketchCanvas` is hidden when Magic Pen isn't in hand and it holds nothing (InkCanvas.swift:336-345), and the follower skips a hidden canvas (:664). |
| 3. Window-level recognizers (`PKPaletteHostView hitTest`) | Partly. `pencilDetector.isEnabled = watchesPencil` (InkCanvas.swift:120-ish). But the window now carries more: `TwistGestureRecognizer`, `restingFingers`, one `PaletteFlick` per window, and an always-on `UIHoverGestureRecognizer` in `PencilBridge` (finding 9 below). |
| 4. ImageLibrary never releasing images | Fixed. Lazy decode at 1600 px into an `NSCache`, `keepDecoded` after the board is idle (ImageLibrary.swift:55-83). Residual: the decode is synchronous on the main actor (finding 17). |
| 5. iCloud status poll | Improved, not replaced. Backoff doubles 3 s to 60 s, stops when the app is inactive, state is read off-main (AppModel.swift:979-1031). Still polling rather than `NSMetadataQuery`. Acceptable. |
| 6. Conflict handling only for the open document | Fixed. `CloudFile.settleConflicts(in:)` walks the whole container off-main (CloudFile.swift:80-90). |
| Undo history cap / close() cancels tasks | Both done (`levelsOfUndo = 50`, DesignStore.swift:47; AppModel.close() cancels conversion, preview, file check). |

## Ranked findings

Ranking is by user-felt impact on an iPad mini: per-frame work first, then hitches, then memory.

### Per-frame, interaction

**1. A selected group or several things re-form a `TurnSession` on every read of `selectionShape`. FIX NOW. Sure: high. Cost: about 0.5 to 2 ms per body at n = 500, several bodies per frame.**
- AppModel.swift:1861-1865 `severalTurn` returns the live session only while one is held and `matches(store)`; otherwise it calls `TurnSession.form` (Model/TurnSession.swift:62-90), which runs `store.things(in:)` (O(n) walk plus `ancestors(of:)` per thing when groups are selected, SeveralThings.swift:49-69), `content.contents(of:)` per group (builds an O(n) dictionary each call, Groups.swift:35) and `store.resolve` per part (linear `screen(id)`).
- `selectionShape` (AppModel.swift:2131-2137), `knobViewPoint` (:2148), `selectionTurn` and `canTurnSelection` (:1812, a second `selectedThings`) each reach it. `RotateKnob.body` reads `knobViewPoint` and `selectionShape` (RotateKnob.swift:36-37), `SelectionLayer` reads `selectionShape` and `selectedThings` twice (SelectionLayer.swift:75, 94). These bodies run on every pan frame (they read `viewport`) and on every drag or turn frame (content changes). With a group selected and no turn under way there is no session, so each read pays the full build: 3 to 5 builds per frame.
- Fix: memoise `severalTurn` and `selectedThings` per (selection, store content version), invalidated by the store's change count; read `store.content` once inside the memo so Observation still tracks. For one group with no session the outline is just the group item's own box, which needs no session.
- Confirm: a DEBUG counter in `TurnSession.form` and `DesignStore.things(in:)`; hosted pan of 60 frames with a group selected should read 0 to 1, not 200+. Time Profiler on a pan with a group selected.

**2. `ShareMenu` generates SwiftUI code on every body evaluation. FIX NOW. Sure: about 80% (relies on `Menu` running its content closure at body time; `ShareLink(item:)` takes a value, so the string is made when the link is built). Cost: O(elements on the screen) of string building, about 1 to 5 ms per frame for a 50 to 100 element screen.**
- Chrome/ShareMenu.swift:19-20: `SwiftUICodeGenerator.code(for:among:settings:)` plus `fileName(for:among:)` (which calls `typeNames` again). `ShareMenu` is always in the top bar (TopBar.swift:341) and reads `model.store.screens`, `selectedScreen`, `canvas.code`, so it re-runs on every store change: every drag, turn and scrub frame. Not in the audit; the call site pre-dates this push, the `among:` argument added more.
- Fix: do not build the string up front. Use a `Transferable` that generates on demand (`ProxyRepresentation` or `DataRepresentation` of a small struct holding the screen id), or turn the row into a `Button` that writes a file and presents the sheet like the other items already do (`share(_:)`, `CodeFiles.write`).
- Confirm: add an increment to `SwiftUICodeGenerator.code` (DEBUG) and assert 0 across a hosted 60-frame drag with the share menu on screen.

**3. The target list is rebuilt from scratch on every content change, with O(G*n) and O(G*L*n) work inside `isTarget`. FIX NOW. Sure: high. Cost: about 1 to 2 ms per frame with 20 groups of 10 at n = 500, growing with G*n.**
- Groups.swift:406-415: for each group item, `content.leaves(of:)` (full dictionary build, :35) and then `content.isHiddenWithItsGroups($0.id)` per leaf, which uses `DesignContent.element(id)`, a linear `elements.first` (Design file :113). The memo (`keptTargets`, DesignStore.swift:~80) is dropped on every content change (`targets = nil`, :29), and `ElementTargets.body` asks again every frame of a drag (SelectionLayer.swift:835). Hover shares the same rebuild after the first move following a change.
- Fix: one pass. Walk each non-group element that is not hidden (with its groups, using the store's index and `groups(above:)`), and mark every group above it as "has something showing". `isTarget` then reads the set in O(1). The whole rebuild becomes O(n * depth).
- Confirm: `CanvasWork.targetPasses` exists; add a time-weighted counter or sample in Time Profiler during a hosted group drag. A micro-benchmark of `targetElements` at G=30, n=600 before and after is enough.

**4. `keepGroupsSound()` runs five O(n) passes with about eight dictionary builds on every change when any group exists. PLAN. Sure: high on mechanism, medium on cost. Cost: about 0.3 to 1.5 ms per change at n = 500, 3 to 6 ms at n = 2,000, paid on every drag, turn and scrub frame.**
- Groups.swift:135-142, called from DesignStore.swift:962-965 (`applying`). `hasGroups` is an O(n) scan (:20); `ungroupStrays` builds `groupItemsByID` and allocates a `Set` per member (:144-166); `dissolveHollowGroups` builds two dictionaries per loop turn (:170-190); `gatherMembers` runs `children(of:)`, `gathered` (three dictionaries, two sorts) and a `map` compare per host with a group (:193-205); `fitGroupBoxes` copies whole `DesignElement`s into per-group arrays (:262-266) and recurses.
- Fix: have `DesignContent` track what a change touched. `update` knows whether `group`, `kind`, `parent`, `isHidden` or the order changed; a frame-only or rotation-only update (every drag/turn/scrub frame) needs neither passes 1 to 4 nor `hasGroups`. Pass 5 then only needs the ancestors of the changed ids. Keep a full pass for `add`, `remove`, `move`, `reorder`, `setChildren` and after undo.
- Confirm: extend `ListWork` with a `groupPasses` counter and assert a hosted group drag runs 0 full passes after the first frame. Existing tests for group soundness must still pass (they run the full pass on structural changes).

**5. Every change compares the whole design, and `DesignElement.ink: Data` is compared byte for byte. PLAN. Sure: mechanism high (no documented pointer-equality shortcut in `Data ==`), cost depends on how much ink the design has: about 0.1 ms per MB per comparison, 2 to 3 comparisons per frame.**
- DesignStore.swift:26-28 `content != oldValue` (elements, frames, unread, canvas); DrawingSync.swift:85-87 `wanted != shown` with `Shown.ink` (every frame via `showDrawings`, AppModel.swift:410); `needsPreview` and `board == shown` after idle (AppModel.swift:1072-1077, 1143); `DesignContent.update` compares the element (Design file :140-150). Mutating `content` while `before` is held also forces one copy-on-write copy of the `elements` array per change, about n * 450 B plus retains of every string and Data field in it.
- Fix: give ink an identity. Either wrap it (`struct InkData: Equatable { let data: Data }` whose `==` first compares `data.withUnsafeBytes { $0.baseAddress }` and count), or give drawing elements an `inkRevision` bumped when ink is written and compare that. Both keep the encoded format.
- Confirm: Time Profiler `memcmp` under `DesignContent.==` and `DrawingSync.strokes` in a hosted drag on a design with a few large drawings.

**6. With the Layers panel open, every content change rebuilds the whole tree and every row's closure. PLAN. Sure: high. Cost: about 1 to 4 ms per frame at n = 500 (rows themselves are `.equatable()` so their bodies are skipped; `LayersPanelWork.rows` shows this).**
- LayersPanel.swift:90-135 reads `store.screens`, `model.hovered`, `model.selection`, `model.enteredGroups`; `layerTree(on:)` (Groups.swift:696-713) runs `children(on:)`, which is an O(n) `filter` per host (S+1 hosts, so O(S*n)), a `SiblingLists` and a dictionary per host, and copies each `DesignElement` into a `LayerNode`. `store.drawings` adds another filter (:717). `branch(...)` returns `AnyView` (:153-164), which the earlier audit counted at zero; it defeats diffing of the subtree and rebuilds the `MoveActions` modifier, `LayerDropList` and accessibility actions for every row every time.
- Fix: memoise `layerTree` in the store keyed on a structural signature (ids, order, group, kind, name, isLocked, isHidden): frame, rotation and colour changes then reuse it. Replace `AnyView` with a recursive `struct LayerBranch: View`. Read `hovered` in the rows (or a small child) rather than the list body, so a pen moving over the canvas does not rebuild the list.
- Confirm: a `LayersPanelWork.trees` counter; hosted drag with the panel open should build 0 trees after the first frame.

**7. Panning with anything selected re-runs the whole selection overlay each frame. PLAN. Sure: high. Cost: O(selected) plus finding 1; about 0.2 to 1 ms per frame with a single element selected, more with a group.**
- SelectionLayer.swift:25 `let viewport = model.viewport` reads both axes; the body builds handles, outline, knob, `SpacingOverlay` and `ForEach(things)` drag areas for every selected thing (:74-97) each pan frame. `RotateKnob.swift:37`, `HoverOutline` (CanvasScreen.swift:440) and `OnCanvas` (:531) read it too.
- Fix: hand the viewport-dependent drawing to a small child that takes resolved canvas shapes (Equatable) and reads `viewport` itself; the parent then depends on the selection and the content only. Drag areas that never change shape on a pan can be placed with `InViewport`'s transform, as `ElementTargets` is.
- Confirm: Instruments' SwiftUI "Long View Body Updates" while panning with one element and with a group selected; or counters on `SelectionLayer.body`.

**8. Pen hover: low, but two cheap fixes. FIX NOW (the Scrubber one). Sure: high. Cost: tens of microseconds per event.**
- CanvasScreen.swift:69-81 runs per hover event: `model.pencilVoice.hovered()` (creates `PencilVoice` on the first event; reads `UIPencilInteraction.preferredSqueezeAction` through `squeezeIsOff()` each event when no call is up, PencilVoice.swift:107, 245), `chromeFrames.values.contains`, `hoverTarget` (reversed scan of the targets of every host with `TurnedRect.contains`, AppModel.swift:1622-1641, O(n) worst case) and `drawing(at:)` (cached stroke bounds, InkCanvas.swift:938). `hoverTarget` now reaches `leaf(at:in:)` for a group (Groups.swift:346), which walks the group's block only: fine. The `leaves(of:)`-per-group cost is in the rebuild (finding 3), not per move.
- `ZoomControl`'s hover handler builds a new `Scrubber.Target` per event (StatusChrome.swift:84-90, ZoomStops.swift:64-81): a `Set` from `menuLevels`, four closures. Cache the set as a static and assign `scrubber.hovered` only when entering or when the frame changes.
- `CanvasScreen.body` itself does not read `hovered`; `HoverOutline` does, in its own view. `isInVoiceCall` is read in `CanvasScreen.body` but changes only at call start and end.

**9. Window-level recognizers grew; one is always on. FIX NOW for the hover one, PLAN for the twist wait. Sure: medium on impact.**
- Scrubber.swift:386-418: `PencilBridge` attaches a `UIHoverGestureRecognizer` to the window for as long as the canvas exists, and `WindowSqueeze` keeps a full-window `Color.black.opacity(0.001)` layer plus this view (CanvasScreen.swift:362-368). It only does anything while a ruler is up (`guard scrubber.target != nil`). This is the same shape of cost the earlier audit tied to `PKPaletteHostView hitTest`. Fix: add the recognizer only while `scrubber.wantsSqueeze || scrubber.target != nil` (read it in `updateUIView` so Observation re-runs it), and drop the opaque-ish layer when the handler is off (it already is, via `Squeezable`; check the `PencilBridge` layer separately).
- InkCanvas.swift:281-283: `panGestureRecognizer.require(toFail: twist)` and the same for pinch. With a selection and a finger landing on it, `TwistTracker` stays `.undecided` until the finger drifts 10 pt or 0.25 s pass (Canvas/TwistGestureRecognizer.swift:80-120), so a canvas pan or pinch that starts on the selection can wait that long. Not CPU, but felt. Confirm on device by timing first scroll movement after touch-down on a selection.

**10. Scrubbing a Format field or the zoom. PLAN, low to medium. Sure: medium.**
- Each step calls `target.set` which makes a store change (finding 1 to 6 per step, about 8 pt of finger travel per step) or starts a new glide: `animate(to:)` stops the old `ZoomAnimation` and makes a new `CADisplayLink` (InkCanvas.swift:603-614), restarting the 0.3 s ease from the in-flight viewport. Fine in CPU; the display-link churn is a few per second.
- The ruler is `.glassEffect(.regular, in: .capsule)` over a canvas that is changing underneath (Scrubber.swift:292), plus `.contentTransition(.numericText)` on the label. Glass samples what is behind it every frame; on an A17 Pro mini over a full-screen moving canvas that is the likeliest GPU cost of a scrub. Confirm with the Core Animation instrument (offscreen passes) while scrubbing; fall back to `.regularMaterial` or an opaque capsule if it shows.
- The glide itself is expected cost: PencilKit re-tiles on each `zoomScale` write; shadows are muted by `isCanvasZooming`.

**11. Pinch re-renders the grid tile every frame. FIX NOW if trivial, otherwise PLAN. Sure: medium. Cost: one small `UIGraphicsImageRenderer` per frame (about 0.1 to 0.3 ms) and cache churn.**
- CanvasEffects.swift:44-65: the cache key includes `pixels: Int`, which changes on almost every pinch frame; `cache.removeAll()` at 64 entries. Fix: quantise `pixels` to steps (a step ratio of 1.05) and scale the drawn tile, or render once at the settled scale and use `.tiledImage(scale:)` for the live factor.

**12. The two panel shadows re-render whenever panel content changes. PLAN, low to medium. Sure: low (GPU-side, unmeasured).**
- LayersPanel.swift:34-36 (and the Format panel) put two `.shadow` modifiers, one radius 22, on the whole content. With the Format panel open, X/Y/W/H change on every drag frame, so the panel layer and its shadow are re-rendered each frame. Move the shadow to a static `.background { RoundedRectangle(...).fill(.background).shadow(...) }` so the shadow source never changes. Confirm in the Core Animation instrument.

**13. Pen-up with a large sketch. PLAN. Sure: medium. Cost: tens of ms on the main thread at pen-up for a drawing of hundreds of strokes.**
- InkCanvas.swift:805-815 `followInk` -> `DrawingSync.changes(for:in:)` (DrawingSync.swift:136-195): bridges every PKStroke out of PencilKit (`documentCanvas.drawing.strokes`), builds `existing`, marks for every stroke, and for the touched drawing re-encodes the whole drawing (`DesignElement.drawing(strokes,…)` -> `PKDrawing(strokes:).dataRepresentation()`), which grows as new strokes join an existing drawing within `reach`. During the stroke nothing is done (changes are followed once the tool is put down), which is right. Measure first (Time Profiler at pen-up with a 500-stroke drawing); if it shows, encode off-main from a stroke snapshot and apply the result.

### Per-change

**14. Autosave: the design is JSON-encoded whole, and every drawing's ink is compared with the file on disk. PLAN. Sure: medium. Cost: JSON about 5 to 15 ms at n = 500 on whichever thread the system picks (the audit cites FB13439586: main on iOS); ink compare reads every ink file.**
- DesignFile.swift:646-693 and :701-705: `saved.regularFileContents == data` for each drawing on each save loads the on-disk file into memory and memcmp's it, even though only one drawing changed. Fix: remember the `Data` last written per drawing in the document (`[UUID: Data]`) and compare against that (or reuse a revision from finding 5) before touching the wrapper; keep `.sortedKeys` (it keeps files byte-stable for iCloud) but note its cost.
- Frequency: `register(step)` closes an undo group at the first change of an edit and `endEdit` posts `markNeedsSaving()` once, so autosave is per edit, not per frame. Good.

**15. `delete` makes one `Task` per deleted id. FIX NOW. Sure: high. Cost: small, but unbounded with a big group.**
- DesignStore.swift:235 and :277: `for id in ids { Task { await SketchReadingLog.shared.noteDeleted(id) } }`. Deleting a group of 200 queues 200 tasks hopping to the actor. Make it one `Task` that passes the id set (and add `noteDeleted(_ ids:)`).

**16. The Code tab regenerates well but draws all lines at once. PLAN. Sure: high on mechanism. Cost: about 50 to 200 ms hitch per regenerate with 1 to 2k lines, only while the Code tab is open.**
- LayersPanel.swift:593-668 debounces 300 ms (good) and `Shown` compares the screen each body. `CodeView` (:725-746) is a non-lazy `VStack` with a `ForEach` of `HStack{Text,Text}` per line, and `SwiftHighlighter.attributed` runs for every line on the main actor (:665). Use `LazyVStack`, and highlight in a detached task (or per visible line).

**17. `ImageLibrary.image(_:)` decodes on the main actor inside a view body. PLAN. Sure: high. Cost: about 10 to 30 ms per image (1600 px), at open (first frame) and again after an `NSCache` eviction.**
- Model/ImageLibrary.swift:55-64, called from `ElementView.body` (PhoneScreenView.swift:175). Fix: decode in a detached task at open and after eviction, show the existing gradient placeholder meanwhile, and bump `revision` when ready. `ImageImport.downsampled` is already `nonisolated`.

**18. `refreshPreview()` draws the board thumbnail synchronously on main. PLAN. Sure: medium.**
- AppModel.swift:1109-1117 (called on close, background and share). The idle path (`refreshPreviewInBackground`) already does the drawing off-main. If a close hitch shows in the trace, reuse `thumbnailParts` and render detached with a short wait, or skip the redraw when `previewedBoard == board`.

**19. Smaller per-change items. PLAN, low.**
- `HistoryStep.record` takes the O(n) `Touched` path (two dictionaries and an element-wise compare) when another change lands between two frames of one edit (DesignStore.swift:~1000-1012): a drag with a scrub or an ink follow running together. Rare.
- `SketchReadingLog.rewrite` (Sketch/SketchReadingLog.swift) reads and decodes the whole log file with a new `JSONDecoder` per line on every correction, and the file holds every launch's readings, so it grows without bound. It is an actor so it is off-main, but it is O(file) per correction. Cap or rotate the file; reuse one decoder.
- `DesignIndexer.index` runs on the main actor 3 s after the last change (Intents/DesignIndexer.swift:64-77, 90-103) and builds entities for all screens and elements; fine at n = 500, worth a glance in a trace at n = 2,000.
- `rotationEffect(.degrees(0))` is now applied to every element in `PhoneScreenView` and `FloatingElementView` (PhoneScreenView.swift:34, 124). SwiftUI folds it into the transform, but applying it only when `resolvedRotation != 0` keeps the view tree smaller. Confirm in the SwiftUI instrument; leave if no effect.

### Memory

- Undo history: capped at 50 levels (DesignStore.swift:47). Each step holds its runs' `before` and `after` `DesignContent`; an unchanged `ink` Data is shared, a changed drawing's is a new buffer, so 50 pen-ups on a 300 KB drawing is about 15 MB, and 50 element-list copies of n * 450 B (about 11 MB at n = 500). Acceptable on an iPad mini; a byte budget (drop the oldest steps once the sum passes about 32 MB) is the robust fix. PLAN, low.
- The ink exists up to four times: `DesignContent` (Data), the PencilKit canvas (`PKStroke`s), `DrawingSync` marks and undo steps. Watch it in Allocations with a big drawing.
- Caches: `GridTile.cache` is capped (64); `ImageLibrary` uses `NSCache` plus `keepDecoded`; `SketchReadingLog.entries`/`order` and the log file are unbounded (finding 19).
- Retained closures and loops: `PencilVoice.watch` re-arms `withObservationTracking` per change and ends when the call changes (PencilVoice.swift:733-750); `groupCloseObserver` is removed after use (DesignStore.swift:~1100); typing observers are removed in `stopWatchingTyping`. No leak found by reading.
- Audio: the tap block is `nonisolated` and hands chunks to `AsyncStream`s with bounded buffers (64, 128, 512) (MicrophoneTap.swift:106, DictationRoute.swift:93-94); 0.1 s of mono float is about 19 KB, so the worst case is a couple of MB. Fine.

### Concurrency

- Audio callbacks stay off the main actor; the main-actor hops are one `Task` per 100 ms chunk for `sounded` (DictationRoute.swift:110) and a 100 ms `tick` loop (:156): about 20 wakes a second while listening. Fine. Cancel-on-stop is in place (`tasks` cancelled, :171-176).
- `checkDragAfterChange` now makes at most one task per drag (AppModel.swift:430-440): the old per-frame churn is gone.
- Remaining per-event churn: finding 15 (a task per deleted id), `typingEnded` (a task per end-editing notification), `ZoomAnimation` per scrub step. None is hot.
- No `Observations` stream is left running that I could find; the one at PencilVoice.swift:363 is awaited to completion.

## Safe, contained fixes worth doing before a push

1. Memoise `severalTurn`/`selectedThings` per (selection, content version) (finding 1).
2. Stop generating SwiftUI code in `ShareMenu.body` (finding 2).
3. Replace the per-group `leaves(of:)` and linear lookups in `isTarget` with one pass (finding 3).
4. Attach `PencilBridge`'s window hover recognizer only while a ruler can use it (finding 9, first half).
5. Cache the zoom ruler's target pieces and skip redundant `hovered` writes (finding 8).
6. One `Task` for a delete's log notes (finding 15).
7. Quantise the grid tile size during a pinch (finding 11), if the change is as small as it looks.

Each has a hosted-counter test shape above; none changes the file format.

## To plan

Findings 4 (dirty tracking for group soundness), 5 (ink identity), 6 (memoised layer tree, drop `AnyView`), 7 (selection overlay off the viewport), 10 (scrub ruler glass), 12 (panel shadows), 13 (pen-up encode), 14 (autosave compare), 16 (lazy code view), 17 (off-main image decode), 18 (close-time preview), and the memory budget for undo.

## How to measure first (a short list, since another agent is benchmarking)

- Time Profiler, Release, on the iPad: one pass each of pan with one element selected, pan with a group selected, drag one element, drag a group, turn a group with two fingers, scrub a Format field, scrub the zoom, hover for 10 s with the Layers panel open. Look for `TurnSession.form`, `DesignContent.contents(of:)`, `SwiftUICodeGenerator.code`, `keepGroupsSound`, `DesignContent.==`, `memcmp`, `DesignStore.layerTree`.
- SwiftUI instrument: Long View Body Updates for `SelectionLayer`, `RotateKnob`, `LayersList`, `ShareMenu`, `ElementTargets` during the same passes.
- Core Animation / Animation Hitches: scrub with the ruler up, drag with the Format panel open.

## Controller's decision (2026-11-23)
The benchmark (benchmark.md) shows main 12% faster than origin/main on the canvas workout (pan, zoom, frame drags, Magic Pen), with no regression; that workout selects nothing, so the selection/group findings above are not covered by it. Before the push, the seven safe, contained fixes listed above are made on branch perf/review-fixes, each with a hosted-counter test. Findings 4–7, 10, 12–14 and 16–18 are planned work, not done before the push.
