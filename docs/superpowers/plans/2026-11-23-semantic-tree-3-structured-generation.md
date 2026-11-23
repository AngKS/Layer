# Semantic tree, plan 3 of 6: structured generation, and ScreenBlueprint removed. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every whole screen that a model, Siri or the library writes arrives as the semantic tree, through one reconciler, and `ScreenBlueprint` is gone. After this plan:
- the on-device model writes the outline and hosted models write A2UI 1.0 (the outline is their fallback), with the prompts rewritten, measured and pinned;
- `TreeReconciler` streams every generated update into the store: stable ids, the user's edits protected, hand-added nodes untouched, layout off the main actor, one commit per update, one undo step per generation;
- Siri's Build Screen takes the outline or A2UI JSON and rebuilds an existing screen through the reconciler; the library's templates are outlines;
- A2UI comes in by drop, paste, Files and Siri, with a sheet of diagnostics by reason, and goes out per screen from the Share menu;
- the SwiftUI export walks the tree (Structure or Exact positions). A sketched (free) screen's Structure code is today's reading-order inference, byte for byte; laid-out containers and cards inside it, and column screens, follow §7. It writes `DesignTokens.swift` when tokens are used, uses token names and custom frames' sizes, compiles for every fixture, and is pinned by goldens;
- cards draw their look on the canvas, and laid-out text draws in its engine frame;
- `ScreenBlueprint`, its grammar, `writeGenerated`, the blueprint's `withOnePrimaryAction` and `setElements(replacing: true)` are deleted; Siri's and voice's look words come from `LookWords`.

**Architecture:** Pure pieces live in `Layer/Tree/` (the reconciler, layout ahead of a commit), `Layer/A2UI/` (the A2UI stream) and `Layer/Sketch/` (prompts and the outline stream), all building on macOS for the screen harness. The store gains one commit verb for generated roots and one for imported screens; both tell the rules that the root was laid out off the main actor, so the commit lays nothing out. A main-actor `GenerationWriter` runs each update: snapshot, merge and lay out off the main actor, commit once. The export is rewritten on `TreeContent` and never reads the projection. The canvas still draws the projection (plan 4 rewrites it); plan 3 only adds cards and laid-out text to what the projection hands each screen.

**Tech Stack:** Swift 6 (strict concurrency), `@Observable`, Foundation Models (`LanguageModelSession`, `HostedLanguageModel`), the official A2UI Swift package (`A2UISwiftCore`, `BasicCatalog`), Core Text, Swift Testing, XCUITest, XcodeGen, SwiftPM (the screen harness).

**Spec:** `docs/superpowers/specs/2026-11-23-semantic-tree-design.md`. Read Intent, Goals 5–7, §4, §6 (all of it), §7, §9, §13, §14, My calls 8, 10, 11, 13, 16–18, and "How the work is split" item 3. Plan 1 (`docs/superpowers/plans/2026-11-23-semantic-tree-1-foundations.md`) and plan 2 (`…-2-store-cutover.md`) are the source of every tree and store name used here.

**Starts when:** plan 2 is complete and merged into `feature/semantic-tree`, its Task 12 has filled the "After plan 2" column of `docs/benchmarks/semantic-tree.md`, and plan 1's `scripts/check-generated-swiftui.sh` passes on the branch.

## Pre-flight amendments 2026-11-23

The pre-flight scan is in `.superpowers/sdd/2026-11-23-semantic-tree-3-structured-generation/preflight.md`. The controller accepted every ruling, and each is written into the tasks below. Plan 1's fix wave names the guarded decode `A2UIImporter.decodeJSON(_:)` / `guardedMessages(from:)`, the screen's name and device `A2UIImport.Screen.name` / `.deviceID`, and the exporter's screen form `A2UIExporter.messages(for: TreeScreen, surfaceID:)` / `jsonLines(for: TreeScreen, surfaceID:)`. If they merge under other names, use the merged ones.

- **F1.** Every A2UI decode goes through plan 1's guarded entry point, never the SDK's `parseAll` on text. `A2UIStream` hands the importer its good lines one message per line, not re-wrapped in an array, and T13 greps `parseAll`.
- **F2.** A good stream line is a guarded decode that gives a JSON object yielding at least one A2UI 1.0 message. When the whole-answer read makes the screen, the per-line failures are dropped.
- **F3.** M2: Layer's own A2UI carries the screen's name and device. T8's `document` takes the screen. T10 and T11 use them when trusted. An untrusted import ignores `createSurface`'s `extensions.layer` too.
- **F4.** Round trips (T8, T10) compare as plan 1's `A2UIExportTests.expectSame` does, so the root's padding, which `TreeRules` writes, is left out.
- **F5.** No new waits. T8's tests use plan 1's `importJSON(_:)`, and T10's tests use plan 1's exporter, not T8's `document`.
- **F6.** A stack's cross-axis `.fill` exports as its leading (or top) alignment, plus a filling frame on each child the engine stretches. Toggles, checkboxes, radios, avatars and symbols get none (M3/A10).
- **F7.** T1's tests use laid-out groups where a container holds no child or one, and a free group of two where it must stay free. T7's fixture adds an empty row (A7: only empty free groups go).
- **F8.** `merge.dropped` is the written keys absent from the whole generated tree. A node the generator moved to another parent is moved, never dropped.
- **F9.** An untrusted import also ignores `LayerGrid`'s `columnSpacing` and `rowSpacing`, and uses the tokens instead.
- **F10.** The A2UI prompt says `LayerGrid`'s `columns` is required. The harness package depends on swift-json-schema (`JSONSchema`, `OrderedJSON`), has stubs for `SystemSymbol` and `ModelPreferences.serverURL`, and copies `ScreenDrawing.swift` when it exists. `laidOut`'s counting is DEBUG only.
- **F11.** `-only-testing` takes struct names: see the table in the Global Constraints. Nested `HostedWindowSuites` suites, and a run of 0 tests counts as a failure.
- **F12.** Clause (f) gains `ScreenGenerator.stream(_:board:using:)`. T13 ports `OutlineTests:198`, renames `ScreenBlueprintTests` and edits `LookWords.swift`'s comment. T3 drops `SystemSymbolTests`. `CodeOfElements` keeps every signature today's tests call.
- **F13.** No test asserts an exact value of a global counter. Template previews and A2UI documents are counted per name and per surface.
- **F14.** Build Screen: H is compared by its record, frame left out. The `nothingInA2UI` payload has a `createSurface`, and the error carries the missing root's message. Call 7's re-lay and the outline's polish are accepted.
- **F15.** The spec's §7 and My call 11 record call 12. "Leaf code moved over unchanged" means the view; its sized frame and placement tail split off.
- **F16.** `Look.apply(to element:)` goes through `Look.apply(to node:)`, so the rule lives once.
- **F17.** Lane B runs the check script with its own simulator and DerivedData after T7, T8 and T9. T12's and T13's measurements run on a quiet machine.
- **F18.** Only `ScreenDrawing` and `DesignScreen.drawing` carry the projection marker. `ElementView`'s additions don't.
- **F19.** T10 keeps the import report in view state, not in `AppModel.swift`, which is lane A's. Its UI test inlines the login JSON.
- **F20.** Spec §9's reporting of unfixable issues in generated and imported trees is deferred to plan 6, and recorded in the ledger in T13.
- **F21.** `DesignTokens` and `GridRow` join the reserved view names.

## Calls made in this plan

1. **Merge and lay out off the main actor from a snapshot; commit only over that snapshot.** For each update, the writer takes the screen's root, its device id and the design's settings (values). It merges and lays out in a detached task, and commits with the hint (call 6) only if all three are still as they were. If the person changed the screen, its device or the tokens meanwhile, the merge is done again on the main actor over the screen as it is now, and the rules lay out what that changed.
   - Why: the spec wants layout off the main actor and one commit per update, and a drag landing during the layout must not be overwritten by a stale merge (spec Edge cases, "A generation streaming while the user drags").
2. **What counts as the person's change.** A written node's *record* is every `LayerNode` field but `children`, plus its parent's id. Its `frame` counts only where the frame is the truth (spec §2 Frames): under a free parent, and not for a container sized to fit (whose frame the rules hug).
   - Why: the engine rewrites laid-out frames whenever a sibling changes. Counting them would make every generated node "the person's" the moment anything else moved.
3. **Deleted, or removed by the rules.** After every commit the reconciler reads the committed root back and records each written key from it. A written node missing *at* its commit was removed by the rules (a free group of one dissolving); it is written again, with its id. A written node missing *since* its commit was deleted by the person; its key, and everything that was under it, is never written again.
   - Why: today's `aWrittenElementChangedByHandIsLeftAsItWasChanged` pins "a deleted element isn't brought back", and the rules may remove a node in the very commit that wrote it.
4. **Order.** Within a parent, the generator's nodes take the generator's order. Every other child (hand-added, or the person's and no longer listed there) stays just after the generated node it followed, or first.
   - Why: a hand-added node keeps the neighbour above it, so in a column it doesn't move when the generator adds lines after its anchor (anti-goal: nothing placed moves unasked).
5. **The root.** The reconciler writes only the screen root's `layout` and `source`. Everything else about a root (frame, sizing, padding, name, lock) is the screen's and the rules'.
   - Why: the rules keep a root to its device and pad a column root from its device's tokens. Writing the parsed root's sizing would fight them on every update.
6. **The commit lays nothing out.** `commitGenerated` and `addLaidOutScreens` set a one-shot hint: for that change, `TreeRules` is given a `previous` in which that screen already has the committed root. So the rules find nothing dirty there (spec §4, "so the commit finds nothing dirty"). `TreeRules` itself is unchanged.
7. **Build Screen over an existing screen** starts a reconciler by *adopting* the screen: each node with a `source.key` counts as written, as it is now (the first one in pre-order when two share a key). The root takes the generated layout. Hand-made nodes (no key) stay, at their place in the order (call 4).
   - Why: My call 13 says Build Screen reconciles rather than replaces, and "hand-added nodes are never touched". The person asked for this rebuild, so the built nodes take the new layout.
   - "Never touched" means the reconciler never writes them. Under a root that becomes a column, the engine re-lays them with it (F14).
8. **Hosted format.** `ScreenGenerator.hostedFormat = .a2ui` is one constant. "The outline as the hosted fallback" means flipping it; there's no retry at run time. On-device always writes the outline. Plan 6 measures and may flip it (My call 17).
   - Why: a retry doubles a paid request, and the user decided the default.
9. **A2UI streams one message per line.** The prompt asks for one JSON object per line, and each `updateComponents` adds the next part of the screen.
   - Every line is decoded through plan 1's guarded entry point (B7), never the SDK's `parseAll` on text (F1).
   - A line is good when it decodes to a JSON object that yields at least one A2UI 1.0 message (F2). A bare string, number or `null` is not good, though the SDK parses it to nothing without an error.
   - A line that isn't good is skipped and reported once. A partial graph imports what resolves from `root`.
   - If, once the answer is complete, no line was good, the whole answer is read as one payload, and the per-line failures are dropped. A model that pretty-printed its JSON still gets its screen, just not streamed.
   - Diagnostics are shown only when the answer is complete.
   - Why: half-written JSON can't be parsed, and the SDK parses whole messages.
10. **A model never sets a number.** A generated A2UI screen's Layer look is ignored (`trustsLayerLook: false`). That covers:
    - every component's `@metadata.extensions.layer`;
    - `createSurface`'s `metadata.extensions.layer`, the screen's name and device (F3);
    - `LayerGrid`'s `columnSpacing` and `rowSpacing`, which take the tokens' spacing instead (F9).

    The outline's and the importer's starting spacings come from the design's tokens: the rhythm step nearest each standard value, and the card's padding. Drops, paste, Files and Siri do trust Layer's look, so Layer → A2UI → Layer stays lossless, its name and device included.
    - Why: §14 says "no model ever picks a number". Plan 2 call 15 hands tokens to generation here.
11. **One primary action** applies to every generated screen, whether outline or A2UI (`Outline.withOnePrimaryAction`). It doesn't apply to A2UI imports.
    - Why: it's a rule about generation quality. An import says what its author meant.
    - Build Screen's outline keeps `Outline.parse`'s built-in polish. "Imports" here means A2UI (F14).
12. **Controller amendment: call 12.** In **Structure** mode, a free container (a free screen root included) is exported by today's reading-order inference, moved to read the tree:
    - Its children are read at their host-space frames and angles (`TreeIndex`), in place of `DesignElement`s.
    - The inference is today's: rows by vertical overlap become `HStack`s, gaps become `.padding(.top, …)`, the side margin is inferred, and a last row near the bottom becomes a `Spacer()`.
    - A free `.group` inside a free container is transparent: its members join the enclosing inference at their host-space frames, as today's groups leave the code unchanged.
    - A card, and a container with a row, column, grid or overlay layout, is one item in the inference, at its host-space frame, with today's placement tail. Its own code follows the §7 table.
    - A free container that isn't a screen root and isn't transparent (a free card, or a free group under a laid-out parent) is inferred inside its own content box. It has no safe areas and no bottom `Spacer()`, and is framed to its size.
    - The inferred numbers stay literal, as today. Token names appear only in laid-out containers, cards and column roots.

    **Exact positions** is absolute for everything, as today.
    - Why: sketched (free) screens are Layer's main path, and the user's priority is better structural design. So the export must not regress for them between plans 3 and 5, or after wherever a free root remains.
    - The tests that pin today's inference pass unchanged. Two goldens recorded from today's generator before the rewrite pin it byte for byte (Task 3).
    - The spec records this in §7's table and in My call 11 (F15).
13. **The export's tokens.**
    - Tokens are written only when some code uses a token name. So a sketched screen's code is today's, byte for byte, and its file list doesn't change.
    - When code does use one, `files(for:)` writes one `DesignTokens.swift` first. One screen's code (Share's SwiftUI Code, the code panel, Siri) is the view followed by the same `enum DesignTokens`, so it compiles on its own as today's does.
    - Margins (column roots only): one `margin` when every exported column screen's device has the same margin. Otherwise there is one `margin<DeviceName>` per device (`marginIPhone`, `marginIPad`), named the way type names are made.
    - In laid-out containers, spacing and padding equal to a rhythm step use `DesignTokens.rhythm[i]`. Other values stay numbers.
    - A text whose size is its kind's token writes today's semantic font. Native comes first (§9, layer 1).
    - A card whose fill is the standard one writes `.background(.background.secondary, in: .rect(cornerRadius: DesignTokens.cardRadius))` (§7). Any other fill writes `DesignTokens.cardFill`.
14. **A test-only adapter for the export.** `LayerTests/Support/CodeOfElements.swift` lifts a `DesignScreen`'s elements into a free root and exports that. It also forwards `GenerateSwiftUICodeIntent.code(for: DesignScreen, in: DesignContent)` to the tree's call.
    - Tests written for elements keep passing unchanged, including those that pin today's inference whole. That shows the free-root export is today's.
    - No app code exports from the projection.
    - It carries `// PROJECTION: deleted in plan 6`, so plan 6 finds it.
15. **"Stack" becomes "Structure".** `CodeSettings.Layout.stack` is renamed `.structure`, raw value `"structure"`, and `"stack"` still reads as `.structure`. Siri's `CodeLayoutOption.stack` keeps its raw value, so saved Shortcuts keep working, and only shows "Structure" (My call 11).
16. **Cards and laid-out text are drawn through the projection.**
    - Each projected `DesignScreen` carries its visible cards (outermost first), drawn under all of the screen's leaves. A card without its own fill or radius takes the design's tokens.
    - Leaves whose parent is laid out draw top-aligned, with no line limit and no shrinking (My call 18).
    - A card in a free container that overlaps an earlier leaf draws under it until plan 4's renderer draws nodes in order. Canvas (off-screen) cards aren't drawn: nothing in plan 3 makes one.
    - Why: this is the least that makes generated screens look right. Plan 4 replaces it.
17. **Paste.** The add menu gets an "A2UI" section: "Import A2UI…" (a Files picker) and the system `PasteButton`, which reads without the paste prompt. The canvas also takes ⌘V through `pasteDestination(for: String.self)`. Dropping A2UI text or a `.json` file on the canvas imports it.
    - If ⌘V can't be made to fire on iPadOS 27, that is recorded in the ledger and left to plan 4.
18. **Imports.**
    - Imported screens are made on the canvas's new-screen device, side by side from the drop point or where new screens go.
    - Each is named from its first title (its words, at most 40 characters), else "A2UI Screen".
    - Exception (F3, M2): a surface that carries Layer's own name and device keeps them, since a trusted import reads `createSurface.metadata.extensions.layer`. The device resolves through `settings.device(named:)`, and is the new-screen device when this design doesn't have it.
    - The whole import is one undo step, "Import A2UI".
    - An import with no screen makes no undo step.
    - Why: generation already treats a new screen this way (the device, the placement, and naming from the words). An undo step that changes nothing would be one Undo that seems to do nothing, which today's generation already avoids.
19. **The screen harness** is a SwiftPM package in `Tools/ScreenBenchmarkHarness`.
    - SwiftPM can't reference files outside a package, so `run.sh` copies the app sources it needs into a git-ignored `Sources/ScreenBenchmarkHarness/App/` before each build.
    - Hosted runs go through the app's own `HostedModelClient` to LM Studio, with no keys.
    - Plan 3 measures only the on-device outline wording. It smoke-tests the hosted modes and leaves the format comparison to plan 6.
20. **Templates** are the outline library's screens, added with their structure. Their library thumbnails are laid out and lowered once per name, through the projection's lowering (`// PROJECTION`).
    - Why: today the templates *are* the prompt's examples, so they move with them. The thumbnail view still draws elements until plan 4, and laying a template out on every redraw of the library would be wasted work.
21. **`setElements(_:on:)` only appends.** The `replacing:` parameter goes. A caller that replaced a screen that still held things uses `replaceChildren(of:with:)`.
    - Why: the spec deletes `setElements(replacing: true)`. Keeping the append under its old name spares 27 call sites a rename for nothing.
22. **The board told to a hosted model stays in words** (`SketchPrompt.describe(board:)`). Telling a model a screen as A2UI is plan 6's, with its hosted edits.
    - Why: the board is context for words and voice, not structure to copy. Plan 6 is the first plan whose hosted model edits a screen.
23. **The test-fallout policy gains three clauses**, (f)–(h), below.

## Global Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, Swift Testing for unit tests (`@Suite`, `@Test`, `#expect`). Regenerate the project with `xcodegen generate` after adding files, and commit `Layer.xcodeproj/project.pbxproj` with the task.
- **macOS builds:** everything in `Layer/Tree/` must build on macOS too, because the harnesses compile app sources there. So there is no UIKit and no SwiftUI in `Layer/Tree/`, and text is measured with Core Text. The projection lives in `Layer/Model/Projection/`, never in `Layer/Tree/`. `Layer/A2UI/` may import A2UI modules but not UIKit or SwiftUI either.
  - New: the screen harness also compiles `Layer/Sketch/ScreenPrompt.swift`, `Layer/Sketch/ScreenStream.swift`, `Layer/Sketch/A2UIPrompt.swift` and `Layer/Providers/HostedModelClient.swift`, so they stay free of UIKit and SwiftUI too.
- **Type names:**
  - Every new type that could clash with SwiftUI is nested in `LayerNode`: `LayerNode.Layout`, `.Stack`, `.Grid`, `.Alignment`, `.Padding`, `.Sizing`.
  - In files that import `OrderedJSON`, write the SDK's type as `OrderedJSON.JSONValue`. Plain `JSONValue` stays the app's own (`Layer/Document/JSONValue.swift`).
- **The A2UI package:**
  - URL `https://github.com/a2ui-project/a2ui`, pinned by **revision `07735d6a654ae3ba25951a8753ddd57b344b1169`** (tag `v0.11.0+swift`).
  - Products **`A2UISwiftCore` and `BasicCatalog` only**.
  - Never use `MessageProcessor`, `SurfaceGroupModel`, `A2UISwiftUI` or `BasicCatalogSwiftUI`.
- **Running A2UI content:** an A2UI `action`, `@call` or `callRendererFunction` is never evaluated or run. It is only reported.
- **Decoding A2UI (F1):** every A2UI text is decoded through plan 1's guarded entry point (`A2UIImporter.decodeJSON(_:)` / `guardedMessages(from:)`) or through `importJSON`, which uses it. That covers a file, a paste, a drop, a streamed line and Siri's text. Nothing calls the SDK's `parseAll` on text.
- **Counters (F13):** no test asserts an exact value of a global counter that other suites also raise while they run in parallel. Count per id, name or surface: `LayoutEngine.timesLaidOut(id)`, `GenerationWork.commits(on:)` and `layoutsAhead(of:)`, `CodeWork` per screen, `AssetLibrary.templatePreviewsMade(named:)`, `A2UIExporter.documentsWritten(for:)`.
- **Every `xcodebuild` command** (in this plan, in scripts and in docs) passes `-skipPackagePluginValidation`, and `-skipMacroValidation` too if plan 1's ledger says so.
- **Limits:**
  - tree depth 32;
  - 5,000 nodes per design;
  - grid columns 1–12;
  - A2UI graph depth 50.
- **Layer's numbers:**
  - rhythm 8, 12, 16, 24, 32;
  - margins 20 (phone), 32 (tablet), 48 (desktop), and new: 8 (watch), 20 (other);
  - desktop column at most 1080;
  - card: radius 16, padding 16, fill `RGBColor(hex: 0xF2F2F7)`.

  From plan 2's Task 6 these are `DesignTokens.standard` and the devices' tokens.
- **A2UI identifiers:**
  - Layer's catalogue id is `urn:layer:a2ui:catalog:1`.
  - Layer's own look travels in a component's `@metadata.extensions.layer`.
- **The file:**
  - Version is 4, and `design.json` is encoded with `.sortedKeys`.
  - The older-version message is exactly: `This design was made by an earlier version of Layer and can't be opened by this one.`
  - The newer-version message stays exactly: `This design was saved by a newer version of Layer. Update Layer to open it.`
- **Undo semantics stay.**
  - Every step is a three-way, per-property revert of only its own changes.
  - Gestures, Format runs, voice commands and generations each stay one step.
  - These stay: `putOnTop`, `markNeedsSaving`, `onlyScreen(changedBy:)`, withdrawing steps that change nothing, and the cap of 50.
- **Ids are stable.** No verb or projection write changes a node's id, except duplicate, which makes new ones. New: the reconciler never changes the id of a node it matches, and a key keeps its id across every update of a generation.
- **No layout in a SwiftUI `body`**, and no whole-tree layout on an edit. Layout runs only in `TreeRules`, in the store's change, on read, and off the main actor before a commit. New: a generated, imported or built root is laid out with `TreeRules.laidOut` off the main actor, and its commit lays nothing out unless the screen changed meanwhile.
- **Projection code** carries the comment `// PROJECTION: deleted in plan 6` on every type and extension that exists only for it.
- **Generation keeps its behaviour.** A generation always makes a new screen. The whole generation is one undo step ("Generate Screen"), or part of a spoken command's. The person's own edits meanwhile are steps of their own. An empty result deletes its screen and leaves no step. A screen deleted mid-write stops the model. Build Screen and an A2UI import are each one step.
- **No model picks a number** (§14). A model's output never brings spacing, padding, sizes or Layer metadata into the tree.
- **Prompts are pinned.** Each prompt's default wording is pinned word for word by a test (Task 12). A wording change needs a harness run, recorded in `docs/benchmarks/screen-prompt.md`.
- **Green.** After every task:
  - the app builds;
  - the full unit suite passes;
  - the UI suite fails no test outside plan 1's recorded baseline set (spec My call 19).

  The UI suite runs in Tasks 3, 4, 5, 7, 8, 9, 10 and 13. From Task 7 on, `scripts/check-generated-swiftui.sh` passes after every lane B task and at the end. Lane B runs it with its own simulator and DerivedData (F17):

  ```
  LAYER_SIMULATOR="Layer iPad Pro 11 (st3-lane-b)" \
  LAYER_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/Layer-st3-lane-b" \
    scripts/check-generated-swiftui.sh
  ```
- **Measuring (F17).** Task 12 Step 2 (on-device latencies) and Task 13 Step 5 (store-change p95s) run only while no other lane or `xcodebuild` is running. Record in the ledger that the machine was quiet.
- **The test-fallout policy.** A test written before this plan may be changed or retired only if it asserts one of these:
  - (a) the v1–v3 file or its readers: the JSON keys `elements` or `floating`, a top-level `canvas` object of settings, `drawing.data`, or a version below 4;
  - (b) a flat-list state the tree can't hold:
    - a group pointer to a missing group, a group on another host, or a group that makes a loop;
    - a drawing inside a group's block;
    - a group item that isn't just in front of its members;
  - (c) members of one canvas group at different scales;
  - (d) a write count the tree lowers, such as a container moved as one write instead of one write per member;
  - (e) floating-point noise below 1e-9 from composing transforms through a turned container. Switch to the file's `close` helper, or add one with tolerance 1e-6.
  - New in plan 3:
  - (f) it calls an API this plan replaces, and only the call changes, to its replacement. What it asserts stays. The APIs are:
    - `ScreenBlueprint` (`parse`, `layout(on:)`, `Item`, `applyLook`, `kindWords`, `kind(named:)`);
    - `ScreenGenerator.blueprint(ofFinishedLinesIn:isComplete:)`, `itemCount`, `Update.screen(ScreenBlueprint)`, `screenStream`'s three arguments, and `ScreenGenerator.stream(_:board:using:)`, which becomes `stream(_: Request)` (F12);
    - `writeGenerated`, `setElements(_:on:replacing:)`, `CodeSettings.Layout.stack`, and the export's `DesignScreen` input (`SharedSwiftUICode`, `CodePreview.Shown`).
  - (g) a stubbed hosted model answers in the written form, which hosted models no longer write (call 8). The stubbed answer becomes A2UI lines, and the assertions stay.
  - (h) a record of something this plan deletes: the `ComponentKinds.txt` lines on blueprint sizes are recorded again from the outline.

  No clause covers code a free screen exports in Structure mode: a test that pins today's inference must pass unchanged (call 12).

  Each change is listed in its task, or recorded in the ledger with its clause. Every other failure is a bug to fix, not a test to change.
- **Test commands.** `<Suite>` is the `@Suite` struct's name.
  - Lane A, this worktree:

    ```
    xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
      -destination "platform=iOS Simulator,name=Layer iPad Pro 11 (semantic-tree)" \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Layer-semantic-tree" \
      -skipPackagePluginValidation -only-testing:LayerTests/<Suite>
    ```

  - The full unit suite is the same command without `-only-testing`.
  - The UI suite is the same command with `-testPlan Layer -only-testing:LayerUITests`.
  - **Suite names (F11).** Where this plan names a test file rather than a suite struct, run every struct below, each with its own `-only-testing:LayerTests/<Struct>`. A suite nested in `HostedWindowSuites` runs as `-only-testing:LayerTests/HostedWindowSuites/<Struct>`. Check once that this form runs more than 0 tests; if it doesn't, run `HostedWindowSuites` whole. A run that executes 0 tests counts as a failure.

    | Name in this plan | Structs to run |
    |---|---|
    | SiriIntentsTests | ScreenBlueprintTests (renamed in Task 13), EntityKeyTests, ColourTests, DesignLibraryTests, DesignIndexTests, OpeningDesignTests, DesignActionTests, ImagePlaygroundTests, StrokeScriptTests, LookWordTests, MovingTests |
    | ScreenGenerationTests | ScreenStreamParsingTests, ScreenPromptTests, SketchHintTests, ScreenGenerationLifecycleTests (LMStudioLiveTests is gated) |
    | DesignTests | ElementLayoutTests, ViewportTests, DesignStoreTests, AppModelTests, DesignFileTests, CodeGenerationTests, SymbolCatalogTests, DesignFileNameTests, CloudFileTests, ResourceTests, ClosingTests, FormatPanelEditTests, FileCheckTests, TurnedCodeTests |
    | FreeformTests | SettingsTests, FreeformBehaviourTests, MoreMagicPenTests, MoreCodeTests, ScrubbingTests |
    | MagicPenComponentTests | InnerMarkTests, SmallControlTests, SketchedLayoutTests, NewControlCodeTests |
    | GroupTests | GroupModelTests, GroupCommandTests, SelectingGroupsTests, GroupGeometryTests, GroupAsOneThingTests, LayerTreeTests |
    | LayersPanelTests | HostedWindowSuites/LayersPanelWorkTests |
    | CanvasHitTestTests | HiddenHitTestTests, InkOverAnElementTests, GlideAndFingerTests, PaletteStateInTestsTests, SelectionAreaTapTests, HostedWindowSuites/CanvasFocusTests, HostedWindowSuites/PaletteAndTypingTests |
    | CanvasDragWorkTests | CanvasDragWorkTests, HostedWindowSuites/CanvasTargetsWorkTests |
    | PerformanceFixTests | PerformanceFixTests, HostedWindowSuites/ShareMenuWorkTests, HostedWindowSuites/PencilBridgeWorkTests |
    | HostedModelTests | HostedModelTests, ModelChoiceTests |
    | ConcurrentEditTests | ConcurrentEditTests, ConcurrentEditsGroupedByEventTests |
    | ScreenTidyTests | ScreenTidyTests, VoiceScreenLayoutTests |
    | VoiceToolsTests | VoiceHandlesTests, CanvasPictureTests, VoiceToolsTests |
    | AssetLibraryTests | AssetLibraryTests, AddingAssetsTests, ShapeTests |
  - **Lanes B and C** run in their own worktrees (`.claude/worktrees/st3-lane-b`, `.claude/worktrees/st3-lane-c`). Their branches are `st3/lane-b` and `st3/lane-c`, cut from `feature/semantic-tree` when plan 3 starts. Their commands are the same with:
    - simulator `Layer iPad Pro 11 (st3-lane-b)` or `Layer iPad Pro 11 (st3-lane-c)`, each cloned from `iPad Pro 11-inch (M5)`;
    - DerivedData `$HOME/Library/Developer/Xcode/DerivedData/Layer-st3-lane-b` or `-st3-lane-c`.
  - A lane's task is reviewed, then merged into `feature/semantic-tree`. Resolve `project.pbxproj` conflicts by re-running `xcodegen generate`.
  - When the plan ends, delete the lane worktrees, their simulators and their DerivedData.
- **The harness builds.** `Tools/ScreenBenchmarkHarness/run.sh check` passes at the end of Tasks 12 and 13.

## Review Focus

1. **The person's edits during a streamed generation.** An edit is never overwritten, a deleted written node never comes back, a hand-added node is untouched and keeps its place, and an edit landing during the off-main layout survives. Owned by:
   - Task 1: `aChangedNodeIsLeftAsTheUserLeftIt`, `aDeletedNodeIsNeverBroughtBack`, `handAddedNodesAreNeverTouchedOrMoved`, `aLaidOutFrameIsNotAnEdit`;
   - Task 4: `anEditMadeWhileAnUpdateIsLaidOutIsKept`, and the ported `aWrittenElementChangedByHandIsLeftAsItWasChanged`.
2. **Ids, commits and where layout runs.** Every id outlives later updates, there is one commit per update, and no layout runs on the main actor for a generated, imported or built root. Owned by:
   - Task 1: `idsOfUnchangedNodesSurviveEveryUpdate`, `aCommitOverTheSameScreenLaysNothingOut`;
   - Task 4: `eachUpdateIsOneCommitLaidOutOffTheMainActor`, `everyIDOutlivesTheUpdatesAfterIt`;
   - Task 10: `anImportLaysOutOffTheMainActor`; Task 11: `aBuildLaysOutOffTheMainActor`.
3. **Malformed input from models and people.** This covers half lines, broken or pretty-printed JSON lines, unresolved children mid-stream, repeated keys, empty outlines and rootless A2UI. It never crashes, never commits a half-built screen, and says why. Owned by:
   - Task 4: `aHalfWrittenLineWaitsForTheNext`, `anOpenerAloneWaitsForItsFirstLine`;
   - Task 6: `aBrokenLineIsSkippedAndReported`, `aPrettyPrintedAnswerStillMakesAScreenAtTheEnd`;
   - Task 1: `aRepeatedKeyIsWrittenOnce`; Task 10: `anImportWithNothingUsableMakesNoScreenAndSaysWhy`; Task 11: `nothingToBuildIsRefused`.
4. **Generated SwiftUI compiles, alone and together, is pinned, and a sketched screen's code doesn't regress.** This covers custom frames, custom tokens, grids, overlays, free containers (inferred, with laid-out containers inside), turned, hidden and named nodes. A free screen's Structure code is today's, byte for byte (call 12). Owned by:
   - Task 3: `theSketchedScreensCodeIsTodays`, `theGoldensAreWhatIsWritten`, `oneScreensCodeCarriesItsTokensWhenItUsesThem`, and today's `CodeGenerationTests` and `MoreCodeTests`, unchanged;
   - Task 7: `scripts/check-generated-swiftui.sh` printing `N files typecheck`, and `theStructuresFixtureReadsAndHoldsEachStructure`.
5. **A2UI at the boundary.** Nothing is ever run, a model's Layer look is ignored, Layer's own export comes back as it was, and diagnostics are complete and grouped. Owned by:
   - Task 2: `aModelsLayerLookIsIgnored`;
   - Task 6: `actionsInAGeneratedScreenAreNeverRun`;
   - Task 8: `theSharedFileIsTheScreensA2UI`;
   - Task 10: `layersOwnExportComesBackAsItWas`, `diagnosticsAreGroupedByReason`.

**Order and lanes:**
- Lane A (this worktree): Tasks 1, 4, 5, 6, 12, 13.
- Lane B (`st3-lane-b`): Tasks 3, 7, 8, 9.
- Lane C (`st3-lane-c`): Tasks 2, 10, 11.
- Waits:
  - Task 4 waits for Task 2 to be merged (the outline takes tokens).
  - Tasks 10 and 11 wait for Tasks 1 and 2.
  - Task 13 waits for every other task.
- No two lanes edit the same file before Task 13. Task 13 edits test files of every lane, which is why it waits.
- Lane boundaries (F5, F19):
  - Task 8's tests use plan 1's `importJSON(_:)` (which Task 2 defines as `.standard, true`), not Task 2's overload.
  - Task 10's tests use plan 1's exporter (`jsonLines(for: TreeScreen, surfaceID:)`), not Task 8's `document`.
  - So neither waits across lanes.
  - Task 10 keeps its import report in view state, never in `AppModel.swift`.

---

### Task 1: The reconciler, layout ahead of the commit, and the store's generated commit

**Lane:** A (first)

**Files:**
- Create: `Layer/Tree/TreeReconciler.swift`, `Layer/Tree/TreeRules+Ahead.swift`, `Layer/Tree/GenerationWork.swift`, `Layer/Tree/LayerNode+Counting.swift`
- Create: `Layer/Model/DesignStore+Generated.swift`
- Modify: `Layer/Model/DesignStore.swift`. The change pipeline (`applying`) takes the one-shot laid-out roots (call 6).
- Test: `LayerTests/TreeReconcilerTests.swift`, `LayerTests/GeneratedCommitTests.swift`

**Interfaces:**
- Consumes:
  - from plan 1: `LayerNode`, `TreeContent`, `TreeScreen`, `TreeRules.apply(to:after:measure:)`, `TextMeasure.shared`, `LayoutEngine.timesLaidOut(_:)` (DEBUG), and `Outline.parse(_:isComplete:)` (tests only);
  - from plan 2: `DesignStore.reconcile(_:_:)`, `addScreen(_: TreeScreen)`, `tree`, `act(for:_:)`, `asOwnStep`, `CanvasSettings.device(named:)`, and the change pipeline's `applying(_:to:previous:)`.
- Produces:
  ```swift
  struct TreeReconciler: Sendable {
      /// A node as compared to see whether the person changed it: every field but `children`, `frame` only where it
      /// is the truth (under a free parent, and not a container sized to fit), and its parent's id (call 2).
      struct Record: Equatable, Sendable {
          init(_ node: LayerNode, parent: UUID?, parentIsFree: Bool)
      }
      enum Written: Equatable, Sendable {
          case node(id: UUID, record: Record)     // as the store had it after the commit that wrote it
          case removedByRules(id: UUID)          // gone in that commit: written again, with this id
          case deletedByUser                     // gone since: never written again, nor anything under it
      }
      struct Merge: Sendable {
          var root: LayerNode
          var deletedByUser: Set<String>         // keys found missing since their commit
          var dropped: Set<String>               // written keys absent from the whole generated tree, removed (unchanged by the person) (F8)
      }
      static let rootKey = ""                   // the screen root's key, as `Outline` writes it
      private(set) var written: [String: Written]
      init()                                    // a new screen this generation made: nothing written yet
      init(adopting root: LayerNode)            // an existing screen (Build Screen): its keyed nodes count as written (call 7)
      /// Pure. `generated` is keyed by `source.key` (ids fresh from a parse). `current` is the screen's root now.
      func merged(_ generated: LayerNode, over current: LayerNode) -> Merge
      /// After a commit, from the root the store now holds.
      mutating func record(_ merge: Merge, committed: LayerNode)
  }
  extension LayerNode {
      /// Nodes below this one that aren't containers, hidden or not.
      var leafCount: Int { get }
  }
  extension TreeRules {
      /// A screen's root laid out exactly as `apply` would lay it out on the screen whose device is `deviceID` among
      /// `settings`' devices, for use off the main actor. `previous` (that screen's root before) lets unchanged
      /// containers be reused. Pure.
      static func laidOut(_ root: LayerNode, deviceID: String?, settings: CanvasSettings, previous: LayerNode?,
                          measure: TextMeasure = .shared) -> LayerNode
  }
  extension DesignStore {
      func root(of screenID: TreeScreen.ID) -> LayerNode?
      /// A generator's one write: `root` becomes the screen's root in one change, through `reconcile(_:_:)`. When the
      /// screen's root is still `base`, `root` was laid out from it off the main actor, and the rules lay nothing out
      /// there. False when the screen is gone.
      @discardableResult func commitGenerated(_ root: LayerNode, on screenID: TreeScreen.ID, laidOutOver base: LayerNode?) -> Bool
      /// New screens whose roots were laid out off the main actor, added in one change. The rules lay nothing out for them.
      @discardableResult func addLaidOutScreens(_ screens: [TreeScreen]) -> [TreeScreen.ID]
  }
  #if DEBUG
  enum GenerationWork {          // counted under a lock
      /// Roots committed on this screen by `commitGenerated` or `addLaidOutScreens`.
      static func commits(on screen: TreeScreen.ID) -> Int
      /// Roots of this id laid out by `TreeRules.laidOut`, and how many of those ran on the main thread.
      static func layoutsAhead(of rootID: UUID) -> (total: Int, onMainThread: Int)
  }
  #endif
  ```
- **The merge** (the non-obvious algorithm):

  ```
  merged(G, over C):
    walk C once: id → (node, parent id, parent is free)
    state(key):
      no entry                                        → new
      .removedByRules(id)                             → new, with id
      .deletedByUser                                  → gone
      .node(id, rec), id not in C                     → gone (deleted since; reported in deletedByUser)
      .node(id, rec), Record(C[id]) == rec            → ours(id)
      .node(id, rec), Record(C[id]) != rec            → theirs(id)
    placed = []                                        // ids used, so no node appears twice
    build(g, under parentID):                          // → a node or nil
      key = g.source.key; if key was already placed → nil                  (a repeated key is written once)
      switch state(key):
        gone:         nil                                                  (nor anything under it)
        theirs(id):   C's parent of id != parentID → nil                    (it lives where the person put it)
                      node = C[id] with its own fields as they are
        ours(id):     node = g's fields with id = id
        new:          node = g (its parse id, or the remembered one)
      node.children = children(of: node, generated: g.children, current: C[node.id]?.children ?? [])
    children(of P, generated gs, current cs):
      seq = gs.compactMap { build($0, under: P.id) }                       // the generator's order
      for c in cs in order, where c isn't in seq and isn't ours (hand-added, or the person's and not listed here):
        anchor = the nearest earlier sibling of c in cs that is in seq
        insert c just after anchor (after any others already put there), or first when there is none
      ours nodes in cs that aren't in seq leave P:
        their key is somewhere else in G → they were moved: built where G puts them, with their id (never dropped)
        their key is nowhere in G         → they are dropped, and their key goes in `dropped`           (F8)
    root: id = C.id; layout and source from G; every other root field from C; children = children(of: root, G.children, C.children)
  ```
  `dropped` is decided against the whole of G (all its keys, gathered in the walk), never against one parent's list. Otherwise a node the generator moved would be forgotten, given a new id on the next update, and kept twice (F8).
  `record` walks the merged root:
  - a key whose id is in `committed` becomes `.node(id, Record(that node))`;
  - a key whose id isn't becomes `.removedByRules(id)`;
  - keys in `deletedByUser` become `.deletedByUser`, with every written key below them;
  - keys in `dropped` are forgotten.

  `init(adopting:)` records every keyed node of `root` as `.node`, the first in pre-order when two share a key.
- **The store's hint:** `DesignStore` keeps `laidOutAhead: [TreeScreen.ID: LayerNode]` for the one change a verb makes, and clears it after. `applying` gives `TreeRules.apply` a `previous` whose screen of that id has that root (inserted for a new screen) when the content's root equals it.

- [ ] **Step 1: Write the failing tests** in `TreeReconcilerTests`. `outline(_:)` is `Outline.parse(_:isComplete: true)`. "Commit" means `TreeRules.laidOut` of the merged root on the iPhone, then `record`.
  - `aFirstWriteTakesTheGeneratedTreeAndKeepsTheScreensRoot`:
    - The current root is an empty free root with id R. Merge `outline("title: Settings\nbutton: Save")`.
    - The root's id is R, its layout is the generated root's, and its leaves' ids are the generated leaves' ids.
    - The leaves' keys are `["group:0/title:0", "group:0/button:0"]`.
  - `idsOfUnchangedNodesSurviveEveryUpdate`:
    - An outline of 8 lines (two sections, a card of two, a `row: a | b`, a `grid 2:` of two) is parsed after each line, so each parse gives fresh ids. Each parse is merged and committed.
    - Every key present after update k has the same id after update k+1. The share carried over is exactly 1.0 for all 7 steps.
    - The final leaves' ids are the ids they were first given.
  - `aChangedNodeIsLeftAsTheUserLeftIt`:
    - Commit `"title: Settings"`. Then set the title's text to "Mine" in the current root.
    - Merge `"title: Notifications\nbutton: Save"`. The title's text is "Mine" with the same id, and the button is added.
  - `aDeletedNodeIsNeverBroughtBack`:
    - Commit `"title: A\nbutton: Go"`. Then remove the button from the current root.
    - Merge `"title: A\nbutton: Go\ntext: More"`. The leaf kinds are `[.title, .text]`, and `merge.deletedByUser == ["group:0/button:0"]`.
    - Record it, then merge the same outline again: still no button.
  - `aDeletedContainersChildrenStayGone`: commit `"card:\n  text: A\n  body: B"`, delete the card, then merge it plus `"\nbutton: Go"`. The root's leaves are `[.button]`.
  - `handAddedNodesAreNeverTouchedOrMoved`:
    - Commit `"title: A"`. Append a hand-made text H (no `source`) to the current root's children.
    - Merge `"title: A\nbutton: Go"`. The root's children ids are `[section, H]`, H is equal to what was added, and the section holds `[title, button]`.
  - `surplusWrittenNodesGoUnlessChanged`:
    - Use hand-keyed trees `root[a, b, c]` (keys "a", "b", "c", as A2UI ids). Commit, then merge `root[a, c]`: ids `[a, c]`, and `dropped == ["b"]`.
    - Again, but with b's text changed by the person before the merge: ids `[a, b, c]`, with b's text the person's.
  - `aLaidOutFrameIsNotAnEdit`: commit `"title: A\nbutton: Go"`, set the title's frame to (0, 0, 10, 10) in the current root, then merge `"title: B\nbutton: Go"`. The title's text is "B".
  - `aFrameInAFreeContainerIsAnEdit`:
    - A free group "f" holds two fixed children, "x" at (10, 10, 50, 20) and "y" at (80, 10, 50, 20). It holds two so that the rules don't dissolve it (F7). Commit.
    - Move x to (30, 10, 50, 20) in the current root, then merge with x's text changed.
    - x's frame is (30, 10, 50, 20), and its text is the old one.
  - `theGeneratorsOrderIsKeptAndHandNodesKeepTheirPlace`: the current root is `[a, H, b]` (H hand-made). Merge `[b, a]`, and the order is `[b, a, H]`.
  - `aNodeTheGeneratorMovesGoesWithItUnlessChanged`:
    - c1 and c2 are laid-out groups (columns). Laid-out groups persist empty or with one child, where free groups would be removed or dissolved at commit (F7, A7).
    - Commit `root[c1[x], c2[]]`, then merge `root[c1[], c2[x]]`: x is under c2 with the same id, and `merge.dropped` is empty (F8).
    - Record, then merge `root[c1[], c2[x]]` again: x keeps its id, and no second x appears.
    - Again from the start, with x's text changed by the person: x stays under c1.
  - `aRepeatedKeyIsWrittenOnce`: generated children keyed `["k", "k"]` merge to one child with that key, the first.
  - `aNodeTheRulesRemovedIsWrittenAgainWithItsID`:
    - A free group "g" of one child is merged. The rules dissolve it in the commit, so after `record`, `written["g"] == .removedByRules(id: g.id)`.
    - The next merge has a node keyed "g" with id `g.id`.
  - `adoptingAScreenCountsItsKeyedNodesAsWritten`:
    - The current root is `outline("title: A\nbutton: Go")`, laid out, plus a hand-made text H.
    - Merge `outline("title: B\nbutton: Go\ntext: More")` with `TreeReconciler(adopting:)`.
    - The title has its id and the text "B", the button has its id, there is a new text "More", and H is unchanged.
  - `onlyTheRootsLayoutIsTheGenerators`: a current root named "Mine" with frame (0, 0, 393, 852) merged with a generated root named nil gives the name "Mine", that frame, and the generated layout.

  In `GeneratedCommitTests` (`@MainActor`):
  - `aCommitOverTheSameScreenLaysNothingOut`:
    - A store has one screen with an empty column root, base B.
    - `laid = TreeRules.laidOut(merged.root, deviceID: "iphone", settings: store.tree.settings, previous: B)`.
    - `commitGenerated(laid, on: id, laidOutOver: B)` returns true, `LayoutEngine.timesLaidOut(B.id)` is unchanged across the call, and `store.root(of: id) == laid`.
    - `GenerationWork.commits(on: id)` rose by 1, and one undo removes both leaves.
  - `aStaleBaseGivesNoHint`: `commitGenerated(laid, on: id, laidOutOver: anotherRoot)` raises `timesLaidOut(B.id)` by 1.
  - `addingLaidOutScreensIsOneStepAndLaysNothingOut`: two screens with laid-out roots give 2 ids, both roots' `timesLaidOut` are unchanged by the call, and one undo removes both.
  - `layoutAheadIsCountedWhereItRuns`: `await Task.detached { TreeRules.laidOut(…) }.value` gives `layoutsAhead(of: root.id) == (1, 0)`, and one more call on the main actor makes it `(2, 1)`.
  - `aCommitToAGoneScreenIsRefused`: it returns false, and `store.content` is unchanged.

- [ ] **Step 2: Run them.** Run `TreeReconcilerTests` and `GeneratedCommitTests`. Expected: FAIL (the types don't exist).

- [ ] **Step 3: Implement.**
  - `TreeReconciler` follows the merge above, with one walk to index C and one to build. It is O(N) with dictionaries.
  - `laidOut` builds a one-screen `TreeContent` with `settings` and the device id, applies `TreeRules` after a copy holding `previous`, returns the root, and counts in `GenerationWork`. The counting is under `#if DEBUG`, since the screen harness builds this file for release (F10).
  - The two store verbs set `laidOutAhead` and make one change each: `commitGenerated` through `reconcile(_:_:)`, and `addLaidOutScreens` by appending every screen in one change. So each is one undo step, or part of the acting edit, as plan 2's verbs are; never a step of its own inside a generation's edit. `applying` substitutes `previous` per call 6.

- [ ] **Step 4: Run them.** Run both suites, then `TreeVerbTests`, `StoreOnTheTreeTests`, `ConcurrentEditTests` and `ConcurrentEditsGroupedByEventTests`, and the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "TreeReconciler: generated trees merged by key over the screen as it is, the person's changes and hand-added nodes left alone, laid out ahead and committed once"`

---

### Task 2: Look words for Siri and voice, and the parsers take the design's tokens

**Lane:** C (first)

**Files:**
- Modify: `Layer/Intents/ElementIntents.swift` (`AddElementIntent`, `StyleElementIntent`), `Layer/Voice/VoiceToolbox.swift` (`addElement`'s kind, `apply(look:to:)`, `fits`)
- Create: `Layer/Model/Projection/Look+Element.swift`
- Modify: `Layer/Tree/Outline.swift` (tokens, the blueprint's other row spellings, `withOnePrimaryAction`), `Layer/Tree/DesignTokens.swift` (`spacing(nearest:)`), `Layer/A2UI/A2UIImporter.swift` (`importJSON(_:tokens:trustsLayerLook:)`, `looksLikeA2UI`)
- Test: `LayerTests/LookWordsEverywhereTests.swift`, `LayerTests/ParsersTakeTokensTests.swift`

**Interfaces:**
- Consumes:
  - from plan 1: `Look`, `LookWords.look(from:)`, `LookWords.kind(named:)`, `LookWords.kindWords`, `ColourWords`, `Outline.parse(_:isComplete:)`, `A2UIImporter.importJSON(_:)` and `A2UIImport`, including the fix wave's `A2UIImport.Screen.name` and `.deviceID` (M2);
  - from plan 2: `DesignTokens`, `LayerNode(element:)`.
- Produces:
  ```swift
  // PROJECTION: deleted in plan 6
  extension Look {
      /// What `ScreenBlueprint.Item.applyLook(to:)` wrote, field for field: border width 1 when only a colour is
      /// given, opacity of 99.5% or more read as none, value clamped to 0…1. Implemented through
      /// `apply(to: inout LayerNode)` on a scratch node holding the element's style and content fields, which are then
      /// written back, so the rule lives once (F16).
      func apply(to element: inout DesignElement)
  }
  extension DesignTokens {
      /// The rhythm step nearest `standard`, the smaller on a tie: how the standard 24, 12 and 8 carry over to a
      /// design's own rhythm. Standard tokens give `standard` back.
      func spacing(nearest standard: CGFloat) -> CGFloat
  }
  extension Outline {
      /// The screen root 24, sections, `column:`, rows and grids 12, and cards 8: each becomes `tokens.spacing(nearest:)`.
      /// The card padding is `tokens.card.padding`. `parse(_:isComplete:)` is this with `.standard`.
      static func parse(_ text: String, isComplete: Bool, tokens: DesignTokens) -> LayerNode
      /// Plan 1's one-primary-action rule, on any tree.
      static func withOnePrimaryAction(_ root: LayerNode) -> LayerNode
  }
  extension A2UIImporter {
      /// `tokens` give the importer's starting spacings: each one that isn't 0 goes through `spacing(nearest:)`. With
      /// `trustsLayerLook` false (a model's output), these are all ignored: every component's `@metadata.extensions.layer`,
      /// `createSurface`'s `metadata.extensions.layer` (so the screen's name and deviceID are nil) (F3), and `LayerGrid`'s
      /// `columnSpacing` and `rowSpacing`, which take the tokens' nearest-12 instead (F9). `importJSON(_:)` is `.standard`, true.
      static func importJSON(_ data: Data, tokens: DesignTokens, trustsLayerLook: Bool) -> A2UIImport
      /// Whether text is meant as A2UI JSON rather than an outline: once trimmed, it starts with `{` or `[`.
      static func looksLikeA2UI(_ text: String) -> Bool
  }
  ```
- **The outline also reads** the blueprint's other row spellings, `row -` and `side by side:`, as `row:`, so Shortcuts written for the blueprint keep working. Plan 1 already reads an all-dash line as a section break.

- [ ] **Step 1: Write the failing tests.** In `LookWordsEverywhereTests`:
  - `aLookCanBeGivenToAnElementAlone`: `LookWords.look(from: ["Bordered", " #112233", "20pt", "border 3"]).apply(to: &button)` gives `buttonLook == .bordered`, `tint == RGBColor(hex: 0x112233)`, `fontSize == 20` and `borderWidth == 3`.
  - `controlsTakeTheirStateFromLookWords`, through `Look.apply(to: &element)`:
    - `[off]` on a checkbox gives `isOn == false`.
    - `[selected]` on a radio gives `isOn == true`.
    - `[40%]` on a progress bar gives `value == 0.4`.
    - `[plain, centre, shadow, border red, opacity 50%]` on a button gives `.plain`, `.center`, `hasShadow`, `borderColor == ColourWords.named["red"]`, `borderWidth == 1` and `opacity == 0.5`.
  - `aLookOnANodeAndOnAnElementAgree`: for six look strings, applying to `LayerNode(kind:)`, and applying to a `DesignElement` and then `LayerNode(element:)`, give equal `style` and `content`.

  In `ParsersTakeTokensTests`:
  - `theStandardTokensGiveTodaysSpacing`: for the spec §6 outline, `parse(t, isComplete: true, tokens: .standard)` gives the same layouts and paddings as `parse(t, isComplete: true)` (24, 12, 12, 8, padding 16).
  - `aDesignsRhythmSetsTheOutlinesSpacing`: tokens with rhythm `[4, 10, 20, 40]` and card padding 20 give the root 20, sections 10, the row 10, the grid 10 and 10, the card's column 10, and the card's padding 20.
  - `spacingNearestTakesTheCloserStepAndTheSmallerOnATie`:
    - Rhythm `[8, 16]`: nearest 12 is 8.
    - Standard: nearest 24 is 24, and nearest 8 is 8.
  - `theBlueprintsOtherRowSpellingsStillRead`: `"row - button: A | button: B"` and `"side by side: text: Wi-Fi | toggle"` each give one row of two.
  - `shortcutsWrittenForTheBlueprintReadTheSame`:
    - `"title: Welcome back\ntext field: Email\ntext field: Password\nbutton: Sign in"` gives leaves `[.title, .textField, .textField, .button]` with texts `["Welcome back", "Email", "Password", "Sign in"]`.
    - `"heading: Settings\n\nrow: button: Cancel | button: Done [blue, bold, radius 12]\n---\nbody: Tap a row to change it [text #333333, 15pt]"` gives three sections, the second holding one row. Done's tint is `ColourWords.named["blue"]`, its weight `.bold`, its radius 12. The body's text colour is `RGBColor(hex: 0x333333)`, its size 15.
    - `"icon: heart.fill; switch; separator; Just some words"` gives `[.symbol, .toggle, .divider, .text]`, with symbol `"heart.fill"` and text `"Just some words"`.
    - `"   \n---\n"` gives a root with no children.
  - `onePrimaryActionWorksOnAnyTree`: a hand-built column of two buttons with `buttonLook == nil` gives `[nil, .bordered]`.
  - `importedSpacingComesFromTheTokens`: with rhythm `[4, 10, 20, 40]`, every stack spacing that isn't 0 in the login fixture's import is in that rhythm. With `.standard`, the import equals `importJSON(_:)`'s.
  - `aModelsLayerLookIsIgnored`:
    - A Text whose `@metadata.extensions.layer.style.fontSize` is 60 imports with `fontSize == nil` when `trustsLayerLook` is false, and 60 when it is true.
    - A `createSurface` whose `metadata.extensions.layer` names the screen "Mine" on `"ipad"` gives nil name and deviceID when `trustsLayerLook` is false, and "Mine" and `"ipad"` when it is true (F3).
    - A `LayerGrid` with `columnSpacing` 37 and `rowSpacing` 5 gets spacings of `tokens.spacing(nearest: 12)` when `trustsLayerLook` is false, and 37 and 5 when it is true (F9).
  - `a2uiIsToldFromAnOutline`: `looksLikeA2UI` is true for `"  {\"version\":\"1.0\"}"` and `"[{}]"`, and false for `"title: Hi"` and `""`.

- [ ] **Step 2: Run them.** Run both suites. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - Point `AddElementIntent`, `StyleElementIntent`, `VoiceToolbox.addElement`, `apply(look:to:)` and `fits` at `LookWords.kind(named:)`, `LookWords.kindWords` and `LookWords.look(from:).apply(to:)`.
  - `Look.apply(to element:)` goes through `Look.apply(to node:)`, with no second copy of the field rules (F16).
  - Thread `tokens` and `trustsLayerLook` through `Outline` and the importer, as the Interfaces say (F3, F9).
  - Make `onePrimaryAction(in:)` reachable as `withOnePrimaryAction`.
  - `grep -n "ScreenBlueprint" Layer/Intents/ElementIntents.swift Layer/Voice/VoiceToolbox.swift` finds nothing.

- [ ] **Step 4: Run them.** Run both suites, then `SiriIntentsTests` and `VoiceToolsTests` (their structs, per F11), `VoiceAgentTests`, `OutlineTests`, `A2UIImportTests`, `A2UIExportTests` and the full unit suite. Expected: PASS unchanged, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Look words: Siri and voice read looks and kinds from LookWords; the outline and the A2UI importer take the design's tokens, and a model's Layer look is ignored"`

---

### Task 3: The SwiftUI export walks the tree

**Lane:** B (first)

**Files:**
- Modify: `Layer/Code/SwiftUICodeGenerator.swift`. It is rewritten: the walk, Structure and Exact positions, view names, the navigation title and previews.
- Create:
  - `Layer/Code/SwiftUICodeGenerator+Leaves.swift`: today's leaf views, on `LayerNode`;
  - `Layer/Code/SwiftUICodeGenerator+Inference.swift`: today's reading-order inference (`rows(of:)`, `sharesRow`, margins, gaps, the bottom `Spacer()`), reading items at host-space frames (call 12);
  - `Layer/Code/CodeTokens.swift`: the `DesignTokens` file and the names views use.
- Modify:
  - `Layer/Model/Design.swift`: `CodeSettings.Layout` (call 15), and `DesignTokens` and `GridRow` added to the reserved view names (F21);
  - `Layer/Intents/LayerEntities.swift`: `CodeLayoutOption` shows "Structure";
  - `Layer/Chrome/ShareMenu.swift`: `SharedSwiftUICode` and `CodeFiles` on the tree;
  - `Layer/Chrome/LayersPanel.swift`: `CodePane` and `CodePreview.Shown` on the tree;
  - `Layer/Intents/DesignIntents.swift`: `GenerateSwiftUICodeIntent` on `content.tree`, through a static `code(for:in:)`.
- Create: `LayerTests/Support/CodeOfElements.swift` (call 14), `LayerTests/SwiftUIExportTests.swift`, `LayerTests/Goldens/Code/profile-structure.swift.txt`, `profile-exact.swift.txt`, `DesignTokens-standard.swift.txt`, and `sketch-structure.swift.txt`, which is recorded from today's generator before the rewrite (Step 1)
- Modify (fallout f only): `DesignTests` (:1898), `PerformanceFixTests` (:138–159). `SystemSymbolTests` iterates `Layout.allCases` and needs no change (F12).

**Interfaces:**
- Consumes:
  - from plan 1: `TreeContent`, `TreeScreen`, `LayerNode`, `TreeIndex` (absolute shapes for Exact positions), and the fixtures `design-profile.json` and `design-sketch.json`;
  - from plan 2: `DesignTokens`, `DeviceFrame.margin`, `.maxContentWidth`, `.isCustom`, `TreeContent.device(of:)`, `TreeLift.nodes(from:host:keeping:)` (the test adapter only);
  - today: the leaf views, `SystemSymbol.resolve`, `assetName`, `literal`, `number`, `CodeWork`.
- Produces:
  ```swift
  enum SwiftUICodeGenerator {
      /// What a screen's code needs from its design. Cheap to make: per screen, not per node.
      struct Context: Equatable, Sendable {
          var tokens: DesignTokens
          var devices: [TreeScreen.ID: DeviceFrame]
          var typeNames: [TreeScreen.ID: String]
          var marginNames: [TreeScreen.ID: String]      // "margin", or "marginIPhone" and so on when margins differ
          init(_ content: TreeContent)
      }
      static func typeNames(for screens: [TreeScreen]) -> [TreeScreen.ID: String]     // today's dedupe rule
      static func fileName(for screen: TreeScreen, in context: Context) -> String
      /// One screen's view, then the design's `enum DesignTokens` when the view uses a token name, so it compiles on
      /// its own. What Share, the code panel and Siri give. A free screen of leaves uses none, so it is today's code.
      static func code(for screen: TreeScreen, in context: Context, settings: CodeSettings) -> String
      /// `DesignTokens.swift` first when any view uses a token name, then one file per screen; the views without the enum.
      static func files(for content: TreeContent, settings: CodeSettings) -> [(name: String, source: String)]
      static func tokensFile(in context: Context) -> (name: String, source: String)
  }
  struct CodeSettings { enum Layout: String, CaseIterable, Codable, Sendable { case structure, absolute } }  // "stack" reads as .structure
  extension GenerateSwiftUICodeIntent { static func code(for screenID: TreeScreen.ID, in content: TreeContent) -> String? }
  ```
- **The walk** (spec §7 table, with the controller's amendment to call 12 for free containers):
  - **Free container in Structure mode, a free screen root included:** today's reading-order inference (call 12), over items read at their host-space frames and angles from `TreeIndex`.
    - A free `.group` child is transparent: its members are items.
    - A card, or a container laid out as a row, column, grid or overlay, is one item. It gets today's placement tail, and its own code follows the rows below.
    - Leaves are today's.
    - Below the screen root, the inference runs inside the container's content box, with no safe areas and no bottom `Spacer()`, and the block is framed `.frame(width:height:alignment: .topLeading)` to its size.
  - **Row or column:** `HStack`/`VStack(alignment:spacing:)`. Padding is `.padding(…)`. `justify` becomes `Spacer()`s, and only when no child fills. Fill sizing is `.frame(maxWidth/maxHeight: .infinity)`, fixed is `.frame(width:height:)`, and fit writes no frame.
    - A cross-axis `.fill` alignment (F6, M3/A10) is written as the stack's `.leading` (column) or `.top` (row). Each child the engine stretches gets `.frame(maxWidth: .infinity, alignment: .leading)` (column) or `.frame(maxHeight: .infinity, alignment: .top)` (row).
    - A toggle, checkbox, radio, avatar or symbol is never stretched, as in the engine, so it gets no such frame.
  - **Grid:** `Grid(horizontalSpacing:verticalSpacing:)` with one `GridRow` per row of `columns`.
  - **Overlay:** `ZStack(alignment:)`.
  - **Card:** its layout's code (a free card's inside is inferred, as above), `.padding(…)` and the background of call 13.
  - **Column screen root:** a `VStack` inside the safe area, with `.padding(DesignTokens.<margin>)`, `.frame(maxWidth: DesignTokens.maxContentWidth)` when its device has one, and `.frame(maxHeight: .infinity, alignment: .top)`.
  - **Exact positions:** absolute for everything, as today. Every visible leaf is at its absolute shape from `TreeIndex`, in today's `ZStack(alignment: .topLeading)` with `.frame` and `.offset`. A card draws as a background shape at its own absolute shape, just before its descendants.
  - **Leaves:** today's native views and styling, `.rotationEffect`, and names as comments.
  - **Left out:** hidden nodes, drawings and the open canvas.
  - **The navigation title:** the first title in reading order becomes `.navigationTitle`, inside a `NavigationStack`.
  - **Previews:** a custom frame's preview is `#Preview(traits: .fixedLayout(width:height:))`. Others keep today's `#Preview`.
  - `CodeWork.wrote(screen.id)` is counted once per screen's code.

- [ ] **Step 1: Record today's code, then write the failing tests** in `SwiftUIExportTests`.
  - Before the generator changes, record `sketch-structure.swift.txt` with today's `SwiftUICodeGenerator.code(for:settings:)` on a `DesignScreen` holding the `design-sketch` fixture's four leaves at their frames (`CodeSettings()`, the screen named as in the fixture). Commit it with the tests.
  - Trees are built in code unless a fixture is named. "Contains" means a line equal to the quoted text, trimmed.
  - `aRowOrColumnIsAStack`: a column root (spacing 16, alignment `.start`) holds a row (spacing 12, alignment `.center`) of two texts. The code contains `VStack(alignment: .leading, spacing: DesignTokens.rhythm[2]) {` and `HStack(alignment: .center, spacing: DesignTokens.rhythm[1]) {`.
  - `aSpacingOffTheRhythmIsANumber`: spacing 10 gives `spacing: 10)`.
  - `crossAxisFillStretchesAllButFixedShapes` (F6): a column with alignment `.fill` holds a text field and a toggle.
    - It contains `VStack(alignment: .leading, spacing:`.
    - The text field's lines include `.frame(maxWidth: .infinity, alignment: .leading)`, and the toggle's lines don't.
  - `justifyBecomesSpacers`:
    - A row with `spaceBetween` and three fixed children has exactly 2 `Spacer()` lines.
    - With `center`, its first and last lines inside are `Spacer()`.
    - With one child filling, it has none.
  - `sizingBecomesFrames`: a fill child gives `.frame(maxWidth: .infinity)`, a fixed 120×44 child gives `.frame(width: 120, height: 44)`, and a fit child gives no `.frame(` line.
  - `aGridIsAGridOfRows`: a 2-column grid with spacings 12 and 8 holding four texts contains `Grid(horizontalSpacing: DesignTokens.rhythm[1], verticalSpacing: DesignTokens.rhythm[0]) {` and exactly two `GridRow {`.
  - `anOverlayIsAZStackWithItsAlignment`: alignment (end, end) gives `ZStack(alignment: .bottomTrailing) {`.
  - `aCardIsAPaddedStackWithItsBackground`:
    - With the standard tokens it contains `.padding(DesignTokens.cardPadding)` and `.background(.background.secondary, in: .rect(cornerRadius: DesignTokens.cardRadius))`.
    - With the design's card fill `0x112233` it contains `.background(DesignTokens.cardFill, in: .rect(cornerRadius: DesignTokens.cardRadius))`, and the tokens file defines `cardFill` as that colour in today's `Color(red:green:blue:)` form.
  - `theSketchedScreensCodeIsTodays`:
    - The `design-sketch` fixture's Structure code equals `sketch-structure.swift.txt`, recorded from today's generator, byte for byte. It contains no `DesignTokens` and no `ZStack(alignment: .topLeading)`.
    - Its Exact positions code contains `.frame(width: 228, height: 40)` and `.offset(x: 20, y: 80)`.
  - `aFreeGroupInAFreeScreenDoesNotChangeTheCode`:
    - A free root `[A, G[B, C], D]`, with G free at (40, 200, 300, 100), gives the same code as a free root `[A, B, C, D]` with B and C at their host frames.
    - With G turned 30, B (own angle 10) is written `.rotationEffect(.degrees(40))`.
  - `aLaidOutContainerInAFreeScreenIsOneItem`: a free root holds a title at (20, 80, 353, 40) and a row (spacing 12, two texts) at (20, 200, 353, 24).
    - The root line is today's `VStack(alignment: .leading, spacing: 16) {`.
    - `HStack(alignment: .center, spacing: DesignTokens.rhythm[1]) {` comes after the title's lines.
    - The code ends with the `enum DesignTokens` block, then nothing but the preview.
  - `aFreeCardIsInferredInsideItsPadding`: a free root holds a free card at (20, 100, 353, 120) with texts at local (16, 16, 150, 24) and (187, 16, 150, 24).
    - The card's block contains `HStack(alignment: .center, spacing: 21) {`, then `.padding(DesignTokens.cardPadding)`, then `.frame(width: 353, height: 120, alignment: .topLeading)`, then the card's background line, in that order.
  - `aFreeGroupInAColumnIsInferredInsideItsBox`: a column root holds a free group (fixed 353×100) with two texts side by side. The group's block contains an `HStack(alignment: .center, spacing:` line, and ends with `.frame(width: 353, height: 100, alignment: .topLeading)`.
  - `exactPositionsFlattenTheProfile`:
    - The `design-profile` fixture in `.absolute` has no `HStack(`, `VStack(` or `Grid(` line.
    - Each visible leaf's `.offset(x:y:)` is its `TreeIndex` host rect's origin, as `number` writes it.
  - `aColumnScreenRespectsTheSafeArea`:
    - The profile's root stack is followed by `.padding(DesignTokens.margin)`, and there is no `.ignoresSafeArea()`.
    - A MacBook Air screen also has `.frame(maxWidth: DesignTokens.maxContentWidth)`.
  - `theTokensFileHoldsTheDesignsTokens`:
    - The standard tokens' file equals the golden `DesignTokens-standard.swift.txt`.
    - Rhythm `[4, 8]` with card padding 20 contains `static let rhythm: [CGFloat] = [4, 8]` and `static let cardPadding: CGFloat = 20`.
  - `marginsAreNamedForTheirDevicesWhenTheyDiffer`:
    - An iPhone column screen and an iPad column screen give `static let marginIPhone: CGFloat = 20` and `static let marginIPad: CGFloat = 32`, and the iPad view uses `.padding(DesignTokens.marginIPad)`.
    - Two iPhone column screens give `static let margin: CGFloat = 20`.
  - `aCustomFramesPreviewHasItsSize`: a custom 198×242 frame gives `#Preview(traits: .fixedLayout(width: 198, height: 242)) {`, and the iPhone gives `#Preview {`.
  - `hiddenNodesDrawingsAndTheCanvasAreLeftOut`.
  - `oneScreensCodeCarriesItsTokensWhenItUsesThem`:
    - The profile's `code(for:in:settings:)` contains `enum DesignTokens {` exactly once, after the view's closing brace.
    - The sketch's contains no `DesignTokens`, and ends with its `#Preview` block, as today.
    - `files(for:)` of the profile names `DesignTokens.swift` first, and no other file contains `enum DesignTokens`.
    - `files(for:)` of a design holding only the sketch's screen has no `DesignTokens.swift`.
  - `viewNamesStayUnique`:
    - Screens named "Sign In", "Sign-In" and "Sign in" are named `SignIn`, `SignIn2` and `Signin3` (today's rule).
    - Screens named "Design Tokens" and "Grid Row" are named `DesignTokensScreen` and `GridRowScreen`, so they don't clash with the code's `enum DesignTokens` or SwiftUI's `GridRow` (F21).
  - `theNavigationTitleComesFromTheFirstTitle`: the profile with `usesNavigationTitle` contains `NavigationStack {` and `.navigationTitle("Profile")`, and no `Text("Profile")`.
  - `structureIsTheDefaultAndStackStillReads`:
    - `CodeSettings().layout == .structure`, and `{"layout":"stack"}` decodes as `.structure`.
    - `CodeSettings.Layout.structure.name == "Structure"`, and `CodeLayoutOption.stack.layout == .structure`.
  - `shareThePanelAndSiriWriteTheSameCode`: `SharedSwiftUICode(…).source`, the code panel's call and `GenerateSwiftUICodeIntent.code(for:in:)` are equal for the profile.
  - `theGoldensAreWhatIsWritten`:
    - For the profile (both layouts) and the standard tokens file, the code equals its golden.
    - With `TEST_RUNNER_LAYER_RECORD_CODE=<dir>` set, the test writes those goldens there instead, as `ComponentCatalogueTests` does.
    - It never records `sketch-structure.swift.txt`, which is today's output and must stay so.

- [ ] **Step 2: Run them.** Run `SwiftUIExportTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the walk, the inference on host-space items, `CodeTokens` and `Context`.
  - Move today's inference over unchanged in what it decides. It now reads items (a leaf, or a laid-out or carded container) with a host-space frame and angle, in place of `DesignElement`s.
  - Move each leaf's view code over unchanged, reading `LayerNode` fields with the same resolved defaults as `DesignElement`'s (F15).
    - "Unchanged" means the view.
    - Today's sized frame and placement tail are split off it. The inference and Exact positions use them as today.
    - Inside a stack, the child's sizing writes the frame instead.
  - Add `DesignTokens` and `GridRow` to the reserved view names (F21).
  - Point the four callers at the tree.
  - Write `CodeOfElements.swift`, whose functions lift `screen.elements` through `TreeLift.nodes(from:host:keeping:)` into a free root and call the tree export. It keeps every signature today's tests call, with today's defaults (F12):
    - `code(for:typeName:settings:)` and `code(for:among:settings:)`;
    - `fileName(for:)` (DesignTests:970) and `fileName(for:among:)`;
    - `files(for:settings:)` and `typeNames(for:)`;
    - `GenerateSwiftUICodeIntent.code(for: DesignScreen, in: DesignContent) -> String`.
  - Record the profile and tokens goldens, read them by eye against §7, and commit them.

- [ ] **Step 4: Run them.** Run `SwiftUIExportTests`. Expected: PASS.

- [ ] **Step 5: Run the suites that use the export.** Run `DesignTests`, `FreeformTests`, `MagicPenComponentTests`, `SystemSymbolTests`, `AssetLibraryTests`, `GroupTests`, `PerformanceFixTests` (with the nested `ShareMenuWorkTests`), `LayersPanelTests` (the nested `LayersPanelWorkTests`) and `SiriIntentsTests`. Names that are files run as their structs (F11).
  - Every test written for elements passes unchanged through the adapter, including those that pin today's inference whole:
    - `theDemoScreenBecomesAVerticalStackInReadingOrder`, `elementsSideBySideTurnInTheirRow` and `aScreenOfAnotherDeviceUsesThatDevicesEdges`;
    - `buttonsSideBySideBecomeAHorizontalStack`;
    - `eachFileEndsWithAPreviewUnlessAskedNotTo`, `everyScreenGetsItsOwnFileName` and `siriNamesAScreensViewAsItsFileDoes`;
    - `GroupTests`' grouped-equals-ungrouped check (:455).
  - A failure is a bug in the export, never a test to change (call 12).

- [ ] **Step 6: Change only the tests the policy allows**, all under (f):
  - `DesignTests` (:1898): `.stack` becomes `.structure`. `SystemSymbolTests` stays as it is (F12).
  - `PerformanceFixTests` (:138–159): `SharedSwiftUICode` and the expected code are made from `store.tree`.

  Record each in the ledger with its clause.

- [ ] **Step 7: Run everything.** Run the full unit suite and the UI suite. Expected: TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 8: Commit.** `git add -A && git commit -m "SwiftUI export: free screens read in reading order as today, laid-out containers as stacks, grids, overlays and cards, the design's tokens in DesignTokens.swift when used, custom frames in previews"`

---

### Task 4: Generation streams through the reconciler

**Lane:** A (waits for Task 2 to be merged)

**Files:**
- Modify: `Layer/Sketch/ScreenGenerator.swift`. It gets `Request`, `Update.screen(LayerNode)` and the outline stream. `blueprint(ofFinishedLinesIn:isComplete:)` and `itemCount` are deleted, and the doc comments name the outline.
- Create: `Layer/Sketch/ScreenStream.swift` (`OutlineStream`), `Layer/App/GenerationWriter.swift`
- Modify: `Layer/App/AppModel.swift`:
  - `generateScreen` adds a `TreeScreen` with an empty column root and writes each update through a `GenerationWriter`;
  - `screenStream` takes a `Request`;
  - `ScreenGeneration.elementCount` counts leaves;
  - a DEBUG `beforeGenerationCommit` hook.
- Modify: `Layer/Model/DesignStore.swift` (`writeGenerated` deleted)
- Modify (fallout f): `ScreenGenerationTests` (the stream suite and the lifecycle suite's helpers), `ConcurrentEditTests` (:29–50; and :393–424, which is in `ConcurrentEditsGroupedByEventTests`), `VoiceAgentTests` (:72, :109, :1196), `VoiceToolsTests` (:966), `ScreenTidyTests` (:595, in `VoiceScreenLayoutTests`), `HostedModelTests` (:254–262, including :255's `ScreenGenerator.stream(_:using:)` call, now in clause (f) (F12))
- Test: `LayerTests/GenerationThroughTheReconcilerTests.swift`

**Interfaces:**
- Consumes:
  - Task 1: `TreeReconciler`, `TreeRules.laidOut`, `commitGenerated`, `root(of:)` and `GenerationWork`;
  - Task 2: `Outline.parse(_:isComplete:tokens:)`;
  - plan 1: `TreeValidator.fixGenerated`;
  - plan 2: `addScreen(_: TreeScreen)`, `act(for:_:)` and the edit verbs;
  - today: `DesignActions.placementForNewScreen`.
- Produces:
  ```swift
  extension ScreenGenerator {
      struct Request: Equatable, Sendable {
          var description: String; var board: String? = nil; var choice: ModelChoice; var tokens = DesignTokens.standard
      }
      enum Update: Equatable, Sendable { case startedWriting; case screen(LayerNode) }   // a keyed root, fixed, not laid out
      static func stream(_ request: Request) -> AsyncThrowingStream<Update, any Error>
  }
  struct OutlineStream: Sendable {            // Layer/Sketch/ScreenStream.swift; builds on macOS
      init(tokens: DesignTokens)
      /// The screen so far when it has more leaves than the last one handed on; nil otherwise.
      mutating func take(_ text: String, isComplete: Bool) -> LayerNode?
  }
  @MainActor final class GenerationWriter {
      struct Prepared: Sendable { let generated: LayerNode; let base: LayerNode; let merge: TreeReconciler.Merge; let laidOut: LayerNode }
      init(screenID: TreeScreen.ID, reconciler: TreeReconciler = TreeReconciler())
      private(set) var reconciler: TreeReconciler
      /// Merged over the screen as it is now and laid out, off the main actor. Nil when the screen is gone.
      func prepare(_ generated: LayerNode, from store: DesignStore) async -> Prepared?
      /// One change. Over `base`, with the hint. Over a screen changed since, merged again here, and the rules lay out
      /// what that changed. Records what was written. False when the screen is gone.
      @discardableResult func commit(_ prepared: Prepared, to store: DesignStore) -> Bool
      /// prepare, then commit inside `edit` (or as a change of its own when nil).
      func write(_ generated: LayerNode, to store: DesignStore, in edit: DesignStore.Edit?) async -> Bool
      #if DEBUG
      var beforeCommit: (@MainActor () -> Void)?   // between the layout and the commit: a test edits here
      #endif
  }
  extension AppModel {
      var screenStream: (ScreenGenerator.Request) -> AsyncThrowingStream<ScreenGenerator.Update, any Error> { get set }
  }
  ```
- **Streaming the outline into keyed updates:**

  ```swift
  mutating func take(_ text: String, isComplete: Bool) -> LayerNode? {
      var root = Outline.parse(text, isComplete: isComplete, tokens: tokens) // the half-written last line waits;
                                                                             // keys are kind:ordinal paths, stable as lines come
      _ = TreeValidator.fixGenerated(&root)                                  // clamps and drops; never re-keys
      guard root.leafCount > handedOn else { return nil }                    // an opener, a fence, a blank: wait
      handedOn = root.leafCount
      return root                                                            // fresh ids: the reconciler maps keys to ids
  }
  ```

  The stream yields `.startedWriting` once, as today, then `.screen(root)` for each non-nil `take`. It throws `nothingWritten` when nothing was handed on.

- [ ] **Step 1: Port the tests that call the old API (f).**
  - The stream suite's six tests call `OutlineStream.take` with the same inputs and assertions. A button's look reads `nil` as filled, so `aScreenHasOnePrimaryAction` still expects `[filled, .bordered, .plain, .plain, .plain]`.
  - Each `written(_:)` helper becomes `.screen(Outline.parse(text, isComplete: true))`.
  - `{ _, _, _ in stream }` becomes `{ _ in stream }`, and `{ description, _, _ in … }` becomes `{ request in … request.description … }`.
  - `HostedModelTests` (:254–262) calls `ScreenGenerator.stream(Request(description: "a tiny screen", choice: .hosted(.openAI, model: "m")))` and counts `leafCount`.

- [ ] **Step 2: Write the failing tests** in `GenerationThroughTheReconcilerTests` (`@MainActor`, `.serialized`; the feed is the lifecycle suite's):
  - `eachUpdateIsOneCommitLaidOutOffTheMainActor`: three updates are fed (a title; plus a text field; plus a button), awaiting the leaf count after each. Counting from just after `generateScreen` returns (it made the screen):
    - `GenerationWork.commits(on: screen) == 3`;
    - `GenerationWork.layoutsAhead(of: rootID) == (total: 3, onMainThread: 0)`;
    - `LayoutEngine.timesLaidOut(rootID)` rose by exactly 3, the layouts ahead and none in the commits.
  - `everyIDOutlivesTheUpdatesAfterIt`: over five updates, the set of node ids after update k is a subset of the set after k+1, for every k.
  - `anEditMadeWhileAnUpdateIsLaidOutIsKept`:
    - After the first update, set `beforeGenerationCommit` to set the title's text to "Mine" through `store.update`.
    - Feed the second update. The title's text is "Mine", the new leaf is there, and `timesLaidOut(rootID)` rose by 3 for that update: once ahead, once for the edit's own change, and once in the commit, which merged again over the edited screen.
  - `aGeneratedScreenIsAColumnOnItsDevice`: after the first update, the root's layout is a vertical stack with spacing 24, and the title's lowered frame minY is `DeviceFrame.iPhone.safeTop + 20`.
  - `aDesignsTokensReachTheGeneratedScreen`: with the design's rhythm `[4, 10, 20, 40]`, the root's spacing is 20.
  - `anOpenerAloneWaitsForItsFirstLine`: `take("title: A\ncard:\n", isComplete: false)` gives nil after the title was handed on.

- [ ] **Step 3: Run them.** Run `GenerationThroughTheReconcilerTests`. Expected: FAIL.

- [ ] **Step 4: Implement.**
  - `OutlineStream` as above.
  - `ScreenGenerator.stream(_:)` with today's sessions, prompt and `room`.
  - `GenerationWriter`: `prepare` copies the root, settings and device id, then runs `merged` and `TreeRules.laidOut` in `Task.detached`. `commit` passes `base` as the hint only when the screen's root, device id and the design's settings are still those three; otherwise it merges again and passes nil (call 1).
  - `generateScreen`: one writer per generation; `write(…, in: edit)` inside today's `withAnimation(.snappy(duration: 0.25))`; `elementCount = root.leafCount`.
  - Delete `writeGenerated`.

- [ ] **Step 5: Run them.** Run `GenerationThroughTheReconcilerTests`, then the ported suites (`ScreenStreamParsingTests`, `ScreenGenerationLifecycleTests`, `ConcurrentEditTests`, `ConcurrentEditsGroupedByEventTests`, `VoiceAgentTests`, the `VoiceToolsTests` structs, `ScreenTidyTests`, `VoiceScreenLayoutTests`, `HostedModelTests` and `ModelChoiceTests`), then the full unit suite and the UI suite. Expected: PASS, every lifecycle assertion unchanged, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Generation: each streamed outline merged by the reconciler and laid out off the main actor, one commit per update; writeGenerated deleted"`

---

### Task 5: The outline prompt, and the library's templates on the outline

**Lane:** A

**Files:**
- Modify: `Layer/Sketch/ScreenPrompt.swift`:
  - `grammar` is written for the outline;
  - `rules` keeps its wording except where it names the written form;
  - the six `library` examples are rewritten in the outline;
  - the `ScreenBlueprint.withOnePrimaryAction` extension is deleted.
- Modify: `Layer/Chrome/AssetLibrary.swift` (`template(named:) -> LayerNode?`, the template thumbnail), `Layer/App/AppModel.swift` (`addTemplate`)
- Modify (fallout f): `ScreenGenerationTests`' `ScreenPromptTests` (the examples read with the outline), `AssetLibraryTests.everyComponentAndTemplateCanBeMade` (`leafCount`)
- Test: `LayerTests/OutlinePromptTests.swift`

**Interfaces:**
- Consumes:
  - Task 2: `Outline.parse(_:isComplete:tokens:)`, `Outline.withOnePrimaryAction`;
  - Task 1: `TreeRules.laidOut`, `leafCount`;
  - plan 1: `TreeValidator.check(_:on:)`;
  - plan 2: `addScreen(_: TreeScreen)`, `TreeProjection.lower(_:pending:)` (thumbnails).
- Produces:
  ```swift
  extension AssetLibrary {
      /// A library screen as an outline root; every node's source is `.template`.
      static func template(named name: String) -> LayerNode?
      /// Its thumbnail's elements: laid out on the iPhone and lowered once per name.  // PROJECTION: deleted in plan 6
      static func templatePreview(named name: String) -> [DesignElement]
      #if DEBUG
      /// Previews made for this name, counted under a lock: tests count per name (F13).
      static func templatePreviewsMade(named name: String) -> Int
      #endif
  }
  ```
- **What the grammar teaches:**
  - one element per line, top to bottom, `kind: words [look]`, with today's look words;
  - `row:`, `card:` and `grid N:` on a line of their own hold the lines indented two spaces under them;
  - `row: a | b` stays a one-line row;
  - a blank line starts a section;
  - the kinds come from `kindNames`.

  It shows the form with a short real example of an indented `card:`, as today's grammar shows real lines.
- **The rules** keep today's text. "Group with blank lines" gains "or in a card". "5 to 14 lines" and "5 to 12 lines" count elements. Task 12 measures the final wording.
- **The library:**
  - settings keeps its one-line rows;
  - product puts its details in a `card:`;
  - profile shows recent work as `grid 3:`;
  - form puts postcode and city in an indented `row:`;
  - empty and sign in stay flat.

  Each has at most 14 elements and one primary action.

- [ ] **Step 1: Write the failing tests** in `OutlinePromptTests`:
  - `everyExampleIsAnOutlineWithOnePrimaryAction`: for each example, `Outline.withOnePrimaryAction(root) == root`, and no `.text` leaf's text names a kind (`LookWords.kind(named:) == nil`).
  - `theLibraryShowsEachContainer`: product's root holds a card, profile's a 3-column grid, and form's a horizontal stack of two text fields.
  - `everyExampleFitsAPhone`: `TreeValidator.check(TreeRules.laidOut(root, deviceID: "iphone", settings: CanvasSettings(), previous: nil), on: .iPhone)` is empty.
  - `theGrammarTeachesTheContainers`: `ScreenPrompt.grammar` contains `"row:"`, `"card:"`, `"grid 2:"` and `"two spaces"`, and still contains every `kindNames` entry.
  - `aTemplateKeepsItsStructure`:
    - `AssetLibrary.template(named: "Product")` holds a card, and every node's `source?.origin == .template`.
    - After `model.addAsset` of `template:Product`, the screen's root is a vertical stack holding a card.
  - `aTemplatePreviewIsMadeOnce`: two calls of `templatePreview(named: "Settings")` are equal.
    - The first call raises `AssetLibrary.templatePreviewsMade(named: "Settings")` by at most 1: another test may already have made it.
    - The second adds 0, and afterwards the count is exactly 1 (F13).

  Port, under (f):
  - `everyKindThatGoesOnScreensIsNamedAndReadsBack` uses `LookWords.kind(named:)`;
  - `everyExampleIsAScreenWithOnePrimaryAction` is replaced by the first test above;
  - `everyComponentAndTemplateCanBeMade` asserts `leafCount >= 4`.

  `aTemplateIsAWholeScreenInOneUndoStep` must pass unchanged.

- [ ] **Step 2: Run them.** Run `OutlinePromptTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the grammar, the rules' two edits, the library, `template(named:)` (parse with `.standard`, then mark `.template`), the memoised preview, and `addTemplate` (`addScreen(TreeScreen(name:origin:scale:deviceID:root:))` inside today's `asOwnStep`).

- [ ] **Step 4: Run them.** Run `OutlinePromptTests`, `ScreenPromptTests`, `AssetLibraryTests`, `AddingAssetsTests` (which holds `aTemplateIsAWholeScreenInOneUndoStep`) and `ScreenGenerationLifecycleTests`, then the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set. `theOnDeviceModelIsToldLess` still holds: compact is under 4,000 characters.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Screen prompt: the grammar and the example library written in the outline, and the library's templates added with their rows, cards and grids"`

---

### Task 6: The A2UI generator for hosted models

**Lane:** A

**Files:**
- Create: `Layer/Sketch/A2UIPrompt.swift`, `Layer/A2UI/A2UIStream.swift`
- Modify: `Layer/Sketch/ScreenGenerator.swift` (`Format`, `hostedFormat`, `format(for:)`, `.leftOut`), `Layer/App/AppModel.swift` (`ScreenGeneration.leftOut`), `Layer/Chrome/GenerateScreenPanel.swift` (`GenerationStatus` says what was left out)
- Modify (fallout g): `LayerTests/HostedModelTests.swift`. The stubbed answers in `aScreenIsGeneratedOnTheCanvasAsItIsWritten` and `aModelIsThinkingUntilItsAnswerStarts` become A2UI lines.
- Test: `LayerTests/A2UIGenerationTests.swift`

**Interfaces:**
- Consumes: Task 2 (`importJSON(_:tokens:trustsLayerLook:)`, `withOnePrimaryAction`), Task 4 (the stream and writer), and plan 1 (`LayerCatalog`, `A2UIDiagnostic`, and the fix wave's guarded entry point `A2UIImporter.decodeJSON(_:)` / `guardedMessages(from:)`, B7). Never the SDK's `parseAll` on text (F1).
- Produces:
  ```swift
  extension ScreenGenerator {
      enum Format: String, Sendable, CaseIterable { case outline, a2ui }
      /// What hosted models write until plan 6 measures (My call 17). Flipping it to .outline is the fallback.
      static let hostedFormat = Format.a2ui
      /// .compact room (on-device, or a hosted model this system can't run) → .outline; otherwise hostedFormat.
      static func format(for choice: ModelChoice) -> Format
      static func stream(_ request: Request, format: Format) -> AsyncThrowingStream<Update, any Error>  // stream(_:) passes format(for:)
      static func instructions(for description: String, using choice: ModelChoice) -> String          // the chosen format's
      enum Update { …; case leftOut([A2UIDiagnostic]) }   // once, after the last screen, when anything was left out
  }
  enum A2UIPrompt {
      static let surfaceID = "screen"
      /// Hosted only, so the full rules, in A2UI's words, and two examples chosen as ScreenPrompt.examples chooses.
      static func instructions(for description: String) -> String
      /// The outline library's six screens as A2UI JSON lines, by the same names.
      static let library: [ScreenPrompt.Example]
  }
  struct A2UIStream: Sendable {
      init(tokens: DesignTokens)
      mutating func take(_ text: String, isComplete: Bool) -> LayerNode?
      /// Once complete: the lines that didn't parse, then the last import's diagnostics.
      var diagnostics: [A2UIDiagnostic] { get }
  }
  extension AppModel.ScreenGeneration { var leftOut: Int }   // diagnostics other than actionNotRun
  ```
- **What the A2UI prompt says:**
  - Write A2UI 1.0 messages, one JSON object per line and nothing else.
  - First a `createSurface` with `surfaceId` `"screen"` and `catalogId` `urn:layer:a2ui:catalog:1`. Then `updateComponents`, each adding the next part of the screen from top to bottom, the root (a `Column`) first.
  - Use only the components that map well: `Column`, `Row`, `Card`, `Text` (`#`/`##` for headings), `Image` (variant `avatar`), `Icon`, `Button` (child `Text`, variant `primary`/`default`/`borderless`), `TextField`, `CheckBox`, `Divider`, `LayerGrid`, `LayerToggle`, `LayerRadio`, `LayerProgress` and `LayerSymbol`.
  - `LayerGrid` must have `columns`, a whole number from 1 to 12: it is required (F10). The prompt names no spacing property, since Layer's tokens set spacing (F9).
  - Every value is a literal: no `@path`, no `@call`. A button's action is `{"event":{"name":"<verb>"}}`.
  - The rules are today's, in A2UI's words. For example, the one primary action is the only Button with variant `primary`.
- **The stream:**

  ```
  take(text, isComplete):
    lines = text split at "\n"; when not complete, the last is left for later
    for each line not looked at yet: trim; skip blanks and code fences
      A2UIImporter.decodeJSON(line) gives a JSON object that yields ≥ 1 A2UI 1.0 message
                                     → good += line                                         (F1, F2)
      else (not JSON, too deep, a bare string/number/null, not an A2UI 1.0 message)
                                     → broken += .parseFailed (with its line number)
    complete and no good line → read the whole answer, fences stripped, as one payload,       // pretty-printed JSON
                                and drop `broken`: those lines were parts of that payload        (F2)
    no new good line → nil
    imported = A2UIImporter.importJSON(Data(good.joined("\n")), tokens:, trustsLayerLook: false)
                                     // one message per line, never re-wrapped in an array (F1)
    root = imported.screens.first?.root → withOnePrimaryAction → nil unless its leafCount grew
  ```

  Each broken line is reported once: by the stream, never again by the importer, since only good lines reach it. The stream yields `.leftOut(diagnostics)` once complete, when there are any other than `actionNotRun`.

- [ ] **Step 1: Write the failing tests** in `A2UIGenerationTests`:
  - `aScreenGrowsMessageByMessage`:
    - The lines are a `createSurface`; then `updateComponents` with a root Column whose children are title, email and go, and the title Text `"## Sign in"`; then the email TextField; then the go Button with its Text.
    - Fed line by line, the leaves are `[.title]`, then `[.title, .textField]`, then `[.title, .textField, .button]`.
    - The keys are `"title"`, `"email"` and `"go"`.
  - `aHalfWrittenLastLineWaits`.
  - `aBrokenLineIsSkippedAndReported`: when the second of four lines is `{"version":"1.0","updateComponents":{`, the screen comes from the others, and `diagnostics` holds exactly one `.parseFailed`.
  - `aPrettyPrintedAnswerStillMakesAScreenAtTheEnd` (F2):
    - The login example is pretty-printed, so it has lines that are bare strings on their own, such as a children array's last id `"go"`.
    - It gives nil until complete, then 4 leaves.
    - `diagnostics` holds no `.parseFailed`.
  - `aBareValueLineIsNotAMessage` (F2): a line `"go"`, `1` or `null` is not good. Alone and complete, it makes no screen and reports `.parseFailed`.
  - `fencesAroundTheLinesAreIgnored`.
  - `aGeneratedScreenHasOnePrimaryAction`: two Buttons with variant primary give filled, then `.bordered`.
  - `aGeneratedScreensLayerLookIsIgnoredWhenStreamed`: `@metadata.extensions.layer.style.fontSize` 60 gives `fontSize == nil`.
  - `actionsInAGeneratedScreenAreNeverRun`: a `callRendererFunction` line gives `.functionNotRun`, and a button's action gives `.actionNotRun`. The stream's `.leftOut` holds the first only.
  - `hostedModelsWriteA2UIAndTheDeviceTheOutline`:
    - `format(for: .appleIntelligence) == .outline`.
    - `format(for: .hosted(.openAI, model: "m"))` is `.a2ui` when `HostedLanguageModel.isSupported`, else `.outline`.
  - `aHostedModelCanStillWriteTheOutline` (gated like `HostedModelTests`): a stubbed outline answer with `format: .outline` gives 2 leaves.
  - `everyA2UIExampleImportsCleanlyAndMatchesItsOutline`:
    - Each `A2UIPrompt.library` example imports to one screen, with diagnostics only `.actionNotRun`.
    - Its leaf kinds, in reading order, are the same-named outline example's. `.body` and `.text` count as one, because A2UI has only `Text` and the importer tells them apart by length.
  - `theA2UIPromptNamesLayersCatalogue`: it contains `urn:layer:a2ui:catalog:1`, `"version":"1.0"`, `createSurface`, `updateComponents`, `LayerGrid` and `LayerToggle`. It says `LayerGrid`'s `columns` is required (F10), and it contains neither `columnSpacing` nor `rowSpacing` (F9).
  - `aGenerationSaysWhatItLeftOut`: feeding `.screen(root)`, then `.leftOut([functionNotRun])`, then finishing gives `generation?.leftOut == 1`.

  Port the two `HostedModelTests` under (g). Their answers become A2UI lines for the same 4 and 2 elements, and every assertion stays.

- [ ] **Step 2: Run them.** Run `A2UIGenerationTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `A2UIPrompt`, `A2UIStream`, the format choice, `.leftOut` handling in `generateScreen`, and the status line ("Finished. 2 parts couldn't be brought in.").

- [ ] **Step 4: Run them.** Run `A2UIGenerationTests`, `HostedModelTests` and `ScreenGenerationTests` (their structs, per F11), and `GenerationThroughTheReconcilerTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "A2UI generation: hosted models write A2UI 1.0 a message per line, streamed through the importer and the reconciler, with what was left out said at the end"`

---

### Task 7: The compile check on the tree's designs

**Lane:** B (after Task 3)

**Files:**
- Modify: `LayerTests/GeneratedCodeExportTests.swift`, `scripts/check-generated-swiftui.sh`
- Create: `LayerTests/Fixtures/Designs/design-structures.json`, `LayerTests/Goldens/Code/structures-structure.swift.txt`, `structures-exact.swift.txt`
- Modify: `Layer/Code/*`, only where the check finds code that doesn't compile, each fix pinned by a `SwiftUIExportTests` case
- Test: `LayerTests/SwiftUIExportTests.swift` (additions)

**Interfaces:**
- Consumes: Task 3's `files(for:settings:)`, `code(for:in:settings:)` and `Context`; plan 1's `TreeManifest.decode` and `TreeRules.apply`; plan 2's custom frames and tokens.
- Produces: `scripts/check-generated-swiftui.sh`, which exits 0 only when every generated file typechecks, and prints `N files typecheck`.
- **`design-structures.json`**, written by hand like plan 1's fixtures:
  - **Screen 1** is an iPhone with a column root. It holds:
    - a row of three, one filling;
    - a 3-column grid of six;
    - a centred overlay of an image and a text;
    - a free group with a child turned 30 and a hidden child;
    - a card holding a card;
    - a text named `Say "hi" 👋`;
    - a filled, a bordered and a plain button;
    - a column with alignment `.fill` holding a text field and a toggle (F6);
    - an empty row, which persists, since only empty free groups go (F7).
  - **Screen 2** is a custom watch frame "Watch 45", 198×242, margin 8, with a column root of a title and a toggle.
  - **Screen 3** is an iPhone with a **free** root, the sketched path (call 12). At asymmetric places it holds:
    - a title;
    - two buttons side by side;
    - a free group of two texts, one turned 15;
    - a laid-out row of a text and a toggle;
    - a free card of an avatar and a text side by side;
    - a button near the bottom.
  - **Settings:** tokens with rhythm `[4, 8, 12, 20, 28]`, card padding 12 and fill `0xE5F0FF`.
- **What `GeneratedCodeExportTests` writes** (enabled by `LAYER_CODE_OUT`, as in plan 1):
  - for every `LayerTests/Fixtures/Designs/*.json` (read, then the rules applied), and for designs built in code:
    - every leaf kind in a column, and every leaf kind on a free root;
    - `DesignTests`' demo screen on a free root, whose code uses no token (so its folders hold no `DesignTokens.swift`);
    - one screen per built-in device family, each with a free root and with a column root;
    - two screens named "Sign In" and "Sign-In";
    - screens named "Design Tokens" and "Grid Row", each with a column root, the second holding a grid, so their code uses `DesignTokens` and `GridRow` beside views of those names (F21);
  - for both layouts × navigation title on and off × preview on and off:
    - `files(for:)` into one folder;
    - each screen's `code(for:in:settings:)` alone into a folder of its own.

- [ ] **Step 1: Write the failing tests** in `SwiftUIExportTests`:
  - `theStructuresFixtureReadsAndHoldsEachStructure`:
    - It decodes.
    - Screen 1's root holds a row, a grid of 3 columns, an overlay, a free group, a card in a card, a hidden node, a `.fill` column and an empty row.
    - Screen 2's device `isCustom`.
    - Screen 3's root is free and holds a free group, a laid-out row and a free card.
  - `aFreeScreenWithStructureInsideReadsInReadingOrder`: screen 3's Structure code has today's root `VStack(alignment: .leading, spacing:` and no `ZStack(alignment: .topLeading)` at all.
    - The two buttons are one `HStack`.
    - The free group's texts are items of the root's inference, at their host frames: no block of their own.
    - The row is `HStack(alignment: .center, spacing: DesignTokens.rhythm[…])`, and the card's block is inferred inside its padding (call 12).
  - `theStructuresGoldensAreWhatIsWritten`: all three screens, both layouts.

- [ ] **Step 2: Run them.** Run `SwiftUIExportTests`. Expected: FAIL (no fixture).

- [ ] **Step 3: Write the fixture and switch the test and the script.**
  - The script typechecks each folder's `*.swift` together with `xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios27.0-simulator`.
  - It exits non-zero on any failure, or when no file was written.
  - Record the two goldens, and read screen 3's by eye against today's inference.

- [ ] **Step 4: Run the check.** Run `scripts/check-generated-swiftui.sh` with lane B's `LAYER_SIMULATOR` and `LAYER_DERIVED_DATA` (Global Constraints, F17). Expected: `N files typecheck`, with N ≥ 100, and exit 0.
  - If it fails, fix the generator, add a `SwiftUIExportTests` case asserting the corrected line, and run it again.
  - Then run `SwiftUIExportTests`, the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Compile check: generated SwiftUI for the tree's fixture designs, free and laid-out screens, custom frames and tokens, typechecks alone and together"`

---

### Task 8: A2UI JSON in the Share menu

**Lane:** B (after Task 3)

**Files:**
- Modify: `Layer/Chrome/ShareMenu.swift` (an "A2UI JSON" item after "SwiftUI Code"), `Layer/A2UI/A2UIExporter.swift` (`document(for:surfaceID:)`)
- Test: `LayerTests/ShareA2UITests.swift`; UI: `LayerUITests/ShareA2UIUITests.swift`

**Interfaces:**
- Consumes: plan 1's `A2UIExporter.messages(for: TreeScreen, surfaceID:)` (the fix wave's screen form, which writes the screen's name and deviceID in `createSurface.metadata.extensions.layer`, M2); Task 3's `typeNames(for:)`; plan 1's `importJSON(_:)` and `A2UIImport.Screen.name` / `.deviceID` (tests). Not Task 2's overload, which is lane C's (F5).
- Produces:
  ```swift
  extension A2UIExporter {
      /// The screen's messages as one JSON array, pretty-printed: a file the importer, and other A2UI tools, read
      /// whole. It carries the screen's name and deviceID (F3).
      static func document(for screen: TreeScreen, surfaceID: String) -> Data
      #if DEBUG
      /// Documents written for this surface id, counted under a lock: tests count per surface (F13).
      static func documentsWritten(for surfaceID: String) -> Int
      #endif
  }
  /// A screen's A2UI, written when shared and not before, like `SharedSwiftUICode`.
  struct SharedA2UI: Transferable, Sendable {
      init(screen: TreeScreen, typeName: String)
      var data: Data { get }            // A2UIExporter.document(for: screen, surfaceID: typeName)
      var fileName: String { get }      // "<TypeName>.a2ui.json"
      static var transferRepresentation: some TransferRepresentation   // FileRepresentation(exportedContentType: .json)
  }
  ```

- [ ] **Step 1: Write the failing tests** in `ShareA2UITests`:
  - `theSharedFileIsTheScreensA2UI`: for the profile fixture's screen, `importJSON(SharedA2UI(…).data)` gives one screen, with no diagnostics.
    - Its root matches the original as plan 1's `A2UIExportTests.expectSame` compares (F4). That is every node's `kind`, `layout`, padding (except the root's, which `TreeRules` writes), sizing, `content`, `style` and `name`, ignoring ids and `source`.
    - The imported screen's `name` and `deviceID` are the original's (F3).
  - `theFileIsNamedForTheScreensView`: a screen named "Sign In" gives `"SignIn.a2ui.json"`.
  - `nothingIsWrittenUntilShared`: making a `SharedA2UI` leaves `documentsWritten(for: typeName)` unchanged, and reading `data` raises it by exactly 1. The surface id is this test's own (F13).

  `ShareA2UIUITests.testTheShareMenuOffersTheScreensA2UI`: add a screen from the library, open Share, and "A2UI JSON" exists.

- [ ] **Step 2: Run them.** Run `ShareA2UITests`. Expected: FAIL.

- [ ] **Step 3: Implement** `document(for:surfaceID:)` and `SharedA2UI`, and add the menu item (symbol `curlybraces`) for the selected screen or the first.

- [ ] **Step 4: Run them.** Run `ShareA2UITests`, `A2UIExportTests`, the full unit suite and the UI suite. Then run `scripts/check-generated-swiftui.sh` with lane B's simulator and DerivedData (F17). Expected: PASS, TEST SUCCEEDED, no UI failure outside the baseline set, and `N files typecheck`.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Share: a screen's A2UI JSON, written when shared, that Layer and other A2UI tools read back whole"`

---

### Task 9: Cards and laid-out text drawn on the canvas

**Lane:** B (after Task 8)

**Files:**
- Create: `Layer/Model/Projection/ScreenDrawing.swift`
- Modify:
  - `Layer/Model/Design.swift`: `DesignScreen.drawing`, stored, not coded;
  - `Layer/Model/Projection/TreeProjection.swift`: each view screen's `drawing`;
  - `Layer/Canvas/PhoneScreenView.swift`: cards drawn under the leaves, `ElementView(element:isLaidOut:)`, and `.card` drawing its fill.
- Test: `LayerTests/CardDrawingTests.swift`

**Interfaces:**
- Consumes: plan 2's `TreeProjection.lower(_:pending:)`, `pose(of:in:)`, `DesignElement(node:frame:rotation:parent:scale:group:)` and `CanvasSettings.tokens`.
- Produces:
  ```swift
  // PROJECTION: deleted in plan 6 (plan 4's renderer draws nodes)
  struct ScreenDrawing: Equatable, Sendable {
      /// The screen's visible cards at their absolute poses, outermost first, as kind `.card`. A card with no fill or
      /// radius of its own takes the design's card tokens.
      var cards: [DesignElement] = []
      /// Leaves whose parent is a row, column, grid or overlay: drawn in their engine frame (My call 18).
      var laidOut: Set<DesignElement.ID> = []
  }
  extension DesignScreen { var drawing: ScreenDrawing }   // stored; not coded. PROJECTION-marked too
  // Not marked: canvas code that plan 4 rewrites. Only ScreenDrawing and DesignScreen.drawing carry the marker (F18).
  extension ElementView {
      init(element: DesignElement, isLaidOut: Bool = false)
      struct TextFit: Equatable { var lineLimit: Int?; var shrinks: Bool; var vertical: VerticalAlignment }
      /// Laid out: no line limit, no shrinking, top-aligned. Otherwise today's per-kind values.
      static func textFit(for kind: ElementKind, isLaidOut: Bool) -> TextFit
  }
  ```

- [ ] **Step 1: Write the failing tests** in `CardDrawingTests`:
  - `aScreensCardsComeWithItsView`: a column root holds a card holding a text.
    - `store.screens[0].drawing.cards.map(\.id) == [card.id]`, and its kind is `.card`.
    - Its frame is `TreeProjection.pose(of: card.id, in: store.tree)?.frame`.
    - Its `tint == RGBColor(hex: 0xF2F2F7)` and its `cornerRadius == 16`.
  - `aDesignsCardTokensColourItsCards`: with the design's card fill `0x112233` and radius 20, the card has those. A card with `style.tint` set keeps its own.
  - `nestedCardsComeOutermostFirstAndHiddenOnesNot`.
  - `laidOutLeavesAreMarked`: the column's leaves are in `laidOut`, and a free root's leaves aren't.
  - `aCardsFillIsDrawnUnderItsText`: render `PhoneScreenView(screen:).environment(ImageLibrary())` with `ImageRenderer` at scale 1, for a screen at scale 1.
    - The pixel at (card.minX + 4, card.midY) is `0xF2F2F7`, each channel within 2/255.
    - The pixel at (card.minX − 4, card.midY) is white.
  - `laidOutTextIsDrawnWholeAndTopAligned`: `textFit(for: .title, isLaidOut: true) == TextFit(lineLimit: nil, shrinks: false, vertical: .top)`, and `textFit(for: .title, isLaidOut: false) == TextFit(lineLimit: 1, shrinks: true, vertical: .center)`.

- [ ] **Step 2: Run them.** Run `CardDrawingTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - The lowering fills `drawing` in the same walk that lowers the screen.
  - `PhoneScreenView` draws `drawing.cards` with each element's frame, rotation and offset before the leaves, and passes `isLaidOut`.
  - `ElementView`'s `.card` case draws a `RoundedRectangle` filled with its tint. The border, shadow and opacity come from today's modifiers.

- [ ] **Step 4: Run them.** Run `CardDrawingTests`, `TreeProjectionTests`, `CanvasHitTestTests`, `CanvasDragWorkTests` and `LayersPanelTests` (their structs, nested ones included, per F11), then the full unit suite and the UI suite. Then run `scripts/check-generated-swiftui.sh` with lane B's simulator and DerivedData (F17). Expected: PASS, TEST SUCCEEDED, no UI failure outside the baseline set, and `N files typecheck`.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Canvas: cards draw their look under what they hold, and laid-out text draws whole in its engine frame"`

---

### Task 10: A2UI comes in: drop, paste and Files

**Lane:** C (waits for Tasks 1 and 2)

**Files:**
- Create: `Layer/App/AppModel+A2UI.swift`, `Layer/Chrome/A2UIImportSheet.swift`, `Layer/Canvas/CanvasDrop.swift`
- Modify:
  - `Layer/Canvas/CanvasScreen.swift`: the drop takes A2UI text and `.json` files besides library assets, and `pasteDestination(for: String.self)` (call 17);
  - `Layer/Chrome/TopBar.swift`: an "A2UI" section with "Import A2UI…" and a `PasteButton`, in the paperclip menu and the narrow window's tools menu;
  - `Layer/A2UI/A2UIDiagnostic.swift`: `Reason: CaseIterable`.
- Test: `LayerTests/A2UIImportFlowTests.swift`; UI: `LayerUITests/A2UIImportUITests.swift`

**Interfaces:**
- Consumes:
  - Task 1: `TreeRules.laidOut`, `addLaidOutScreens`, `GenerationWork`;
  - Task 2: `importJSON(_:tokens:trustsLayerLook:)`, `looksLikeA2UI`;
  - plan 1: `A2UIDiagnostic`, `A2UIImport.Screen.name` / `.deviceID` (M2), and `A2UIExporter.jsonLines(for: TreeScreen, surfaceID:)` (tests). Not Task 8's `document`, which is lane B's (F5);
  - today: `DesignActions.placementForNewScreen`, `AssetLibrary.asset(id:)`.
- Produces:
  ```swift
  struct A2UIImportReport: Identifiable, Equatable, Sendable {
      struct Group: Equatable, Sendable { var reason: A2UIDiagnostic.Reason; var title: String; var diagnostics: [A2UIDiagnostic] }
      let id: UUID
      var screens: [TreeScreen.ID]
      var groups: [Group]                    // one per reason present, in Reason.allCases order
      var needsShowing: Bool { get }         // something was left out, or no screen was made
      static func title(for reason: A2UIDiagnostic.Reason) -> String   // e.g. .actionNotRun → "Actions aren't run in Layer"
  }
  extension AppModel {
      /// Imported and laid out off the main actor, then committed as new screens in one step ("Import A2UI"), as
      /// call 18 says. Trusts Layer's look, so a surface carrying Layer's name and deviceID keeps them; the device
      /// resolves through `settings.device(named:)`, and is the new-screen device when unknown here (F3). No screen
      /// means no step. The caller keeps the report in its own view state, not in AppModel (F19).
      func importA2UI(_ data: Data, near point: CGPoint? = nil) async -> A2UIImportReport
  }
  enum CanvasDrop {
      enum Payload: Equatable { case assets([String]), a2ui(Data) }   // library asset ids, or A2UI text
      static func payload(of strings: [String]) -> Payload?
  }
  extension View { func a2uiImportSheet(_ report: Binding<A2UIImportReport?>) -> some View }   // shown when needsShowing
  ```

- [ ] **Step 1: Write the failing tests** in `A2UIImportFlowTests` (`@MainActor`):
  - `anImportIsNewScreensInOneUndoStep`: the login fixture gives `report.screens.count == 1`. The screen's leaves are `[.title, .textField, .textField, .button]`, and one undo removes it.
  - `anImportLaysOutOffTheMainActor`: the imported root's id is new, and after the import `GenerationWork.layoutsAhead(of: rootID) == (total: 1, onMainThread: 0)` and `LayoutEngine.timesLaidOut(rootID) == 1`: the layout ahead, and none in the commit.
  - `anImportWithNothingUsableMakesNoScreenAndSaysWhy`:
    - An `updateComponents` with no root gives no screens and no undo step.
    - Its groups hold `.missingRoot`, and `needsShowing` is true.
  - `diagnosticsAreGroupedByReason`: the modal fixture's groups are in `Reason.allCases` order, and each group's count is that reason's count among the diagnostics.
  - `everyReasonHasWords`: every `Reason.allCases` entry has a non-empty `title(for:)`.
  - `twoSurfacesBecomeTwoScreensSideBySide`: the second screen's canvas minX is greater than the first's maxX.
  - `anImportedScreenIsNamedFromItsTitle`: the login form gives "Login", and a surface without a title gives "A2UI Screen".
  - `layersOwnExportComesBackAsItWas`: `A2UIExporter.jsonLines(for:surfaceID:)` (plan 1) of the profile fixture's screen is imported (F5).
    - Its root matches as plan 1's `A2UIExportTests.expectSame` compares (F4). That is every node's `kind`, `layout`, padding (except the root's, which `TreeRules` writes), sizing, `content`, `style`, `name`, and the frames of free containers' children.
    - The new screen has the original's name and deviceID (F3). To tell them from call 18's defaults, the test renames the screen and puts it on `"ipad"` before exporting, while the canvas's new-screen device is the iPhone.
  - `dropsAreToldApart`:
    - `payload(of: ["symbol:star"]) == .assets(["symbol:star"])`.
    - A2UI text gives `.a2ui`.
    - `["hello"]` gives nil.

  `A2UIImportUITests.testPastingA2UIMakesAScreenAndSaysWhatWasLeftOut`:
  - Set `UIPasteboard.general.string` to the login fixture's JSON, then tap "Add Image" and then "Paste" in its "A2UI" section. The JSON is written in the UI test as a literal, since the fixture is in the LayerTests bundle (F19).
  - "Actions aren't run in Layer" appears, and "Done" closes the sheet.

- [ ] **Step 2: Run them.** Run `A2UIImportFlowTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `importA2UI` imports in `Task.detached`, then lays out each screen root with `TreeRules.laidOut`, on the surface's own device when it names one this design has, else the new-screen device (F3). Back on the main actor it computes the placements and calls `addLaidOutScreens` inside one named step.
  - If the design's settings changed while it worked, it lays the roots out again first.
  - The canvas drop becomes one handler that reads strings or JSON file data and calls `CanvasDrop.payload`. `CanvasDrop.payload` tells A2UI by `looksLikeA2UI`, a prefix test, and never decodes. Only `importA2UI` decodes, through `importJSON` and the guarded entry point (F1).
  - The Files picker allows `.json` and `.plainText`, reading inside the security scope as `ImageAttaching` does.
  - The sheet lists each group's title, count and component ids.
  - The report lives in view state: TopBar and CanvasScreen each keep an `@State var report: A2UIImportReport?` with its own `.a2uiImportSheet($report)`. `AppModel.swift` is lane A's file, and this task doesn't edit it (F19).

- [ ] **Step 4: Run them.** Run `A2UIImportFlowTests`, `A2UIImportTests` and `AssetLibraryTests` (its structs, per F11), then the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set. Try ⌘V on the canvas in the simulator with a hardware keyboard, and record the result in the ledger (call 17).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "A2UI in: drop, paste or pick A2UI JSON to make screens off the main actor in one step, with what wasn't brought in listed by reason"`

---

### Task 11: Siri's Build Screen through the reconciler

**Lane:** C (waits for Tasks 1 and 2; after Task 10)

**Files:**
- Modify: `Layer/Intents/ScreenIntents.swift`. `BuildScreenIntent`'s description teaches the outline and A2UI JSON, `perform` calls `build`, and `BuildScreenError` is added.
- Test: `LayerTests/BuildScreenTests.swift`

**Interfaces:**
- Consumes: Task 1 (`TreeReconciler(adopting:)`, `TreeRules.laidOut`, `commitGenerated`, `addLaidOutScreens`, `GenerationWork`), Task 2 (`Outline.parse(_:isComplete:tokens:)`, `importJSON(_:tokens:trustsLayerLook:)`, `looksLikeA2UI`), and today's `DesignActions.edit`, `placementForNewScreen` and `LayerIntentError`.
- Produces:
  ```swift
  extension BuildScreenIntent {
      /// What `perform` does. `layout` is A2UI JSON when `A2UIImporter.looksLikeA2UI`, else the outline. A new screen
      /// (no `target`) is laid out off the main actor and added. An existing one is merged by a reconciler that
      /// adopts it and committed through `commitGenerated`. One step through `DesignActions.edit` ("Build Screen").
      @MainActor static func build(_ layout: String, on target: TreeScreen.ID?, name: String?, device: DeviceFrame,
                                   in model: AppModel, undoManager: UndoManager?) async throws -> TreeScreen.ID
  }
  enum BuildScreenError: LocalizedError, Equatable {
      case nothingInA2UI(String)    // the `.missingRoot` diagnostic's message when there is one, else the first diagnostic's (F14)
  }
  ```
- **A2UI here trusts Layer's look** (call 10): `importJSON(_:tokens:trustsLayerLook: true)`. A new screen with no `name` from Siri takes the surface's name when it carries one (F3).
- **The outline keeps its polish.** `Outline.parse` gives Build Screen's outline one primary action, as call 11 says (F14).
- **Refusals:**
  - an outline with no leaves throws `LayerIntentError.invalidBlueprint`, whose message is unchanged;
  - A2UI that makes no screen throws `.nothingInA2UI`;
  - a locked target throws `.locked`.

- [ ] **Step 1: Write the failing tests** in `BuildScreenTests` (`@MainActor`):
  - `aNewScreenIsBuiltFromAnOutline`: `"title: Hi\ncard:\n  text: A\n  body: B\nbutton: Go"` makes a new screen.
    - Its root is a vertical stack, and its leaves are `[.title, .text, .body, .button]`.
    - The card holds `[.text, .body]`, and one undo removes the screen.
  - `aNewScreenIsBuiltFromA2UI`: the login fixture's text gives `[.title, .textField, .textField, .button]`.
  - `rebuildingKeepsWhatWasBuiltAndWhatWasAddedByHand`:
    - Build `"title: A\nbutton: Go"` (ids T and B), then add a hand-made text H with `store.add(_:to: .screen(id))`.
    - Rebuild with `"title: B\nbutton: Go\ntext: More"`. T's text is "B", B keeps its id, and a text "More" is new.
    - H keeps its id and its place, still the root's child just after the section. Its record (every field but `frame`) is unchanged. The column re-lays its frame below the grown section, which is the engine's work, not the reconciler's (F14, call 7).
    - One undo gives back the title "A", no "More", and H.
  - `rebuildingALockedScreenIsRefused`: it throws `.locked`, and `store.content` is unchanged.
  - `nothingToBuildIsRefused`: `"   \n---\n"` throws `.invalidBlueprint`. A `createSurface` followed by an `updateComponents` with no `root` component throws `.nothingInA2UI`, whose message names the root (F14).
  - `aBuildLaysOutOffTheMainActor`: a new screen and a rebuild each leave `layoutsAhead(of: rootID).onMainThread == 0`.
  - `shortcutsWrittenForTheBlueprintStillBuild`: `"heading: Settings\n\nrow: button: Cancel | button: Done [blue, bold, radius 12]\n---\nbody: Tap a row to change it [text #333333, 15pt]"` builds leaves `[.title, .button, .button, .body]`, and Done's tint is `ColourWords.named["blue"]`.

- [ ] **Step 2: Run them.** Run `BuildScreenTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `build` and rewrite the intent's description.
  - Parse, then merge (for a rebuild) and lay out in `Task.detached`, then commit in `DesignActions.edit`.
  - If the screen's root is no longer the snapshot when the edit runs, merge again over the root as it is now, on the main actor, and commit without the hint (call 1).
  - The dialog is "Built \<name\> with N elements", where N is the screen's leaf count.

- [ ] **Step 4: Run them.** Run `BuildScreenTests` and `SiriIntentsTests` (its structs, per F11), then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Build Screen: the outline or A2UI JSON builds a new screen, or rebuilds one through the reconciler, keeping what was added by hand"`

---

### Task 12: The screen harness as a package, and the prompts measured and pinned

**Lane:** A (after Tasks 5 and 6)

**Files:**
- Create: `Tools/ScreenBenchmarkHarness/Package.swift`, `Tools/ScreenBenchmarkHarness/Sources/ScreenBenchmarkHarness/Harness.swift`, `Score.swift`, `Briefs.swift`, and `Tools/ScreenBenchmarkHarness/.gitignore` (`Sources/ScreenBenchmarkHarness/App/`, `.build/`)
- Modify: `Tools/ScreenBenchmarkHarness/run.sh`
- Delete: `Tools/ScreenBenchmarkHarness/Harness.swift` and `LayoutStubs.swift` (the old ones)
- Modify: `docs/benchmarks/screen-prompt.md` (a section for the outline), `docs/benchmarks/semantic-tree.md` (the generation row)
- Modify: `Layer/Sketch/ScreenPrompt.swift`, only if the measurement changes its wording
- Test: `LayerTests/ScreenPromptWordingTests.swift`

**Interfaces:**
- Consumes: `ScreenPrompt`, `A2UIPrompt`, `OutlineStream`, `A2UIStream`, `TreeValidator`, `Outline.withOnePrimaryAction`, `LayerCatalog`, `HostedModelClient.stream(_:schema:maximumTokens:temperature:provider:model:key:)`, and the A2UI package at the pinned revision.
- Produces:
  - `run.sh check` builds the package and scores one canned outline answer and one canned A2UI answer, with no model. It prints `harness ok: outline 1/1 valid, a2ui 1/1 valid` and exits 0.
  - `run.sh outline [runs]` uses the on-device model natively on macOS with `ScreenPrompt.instructions(.compact, …)`. It runs the 8 briefs today's harness used.
  - `run.sh hosted <LM Studio model id> <outline|a2ui> [runs]` uses LM Studio through `HostedModelClient`, with `.lmStudio` and no key.
  - Each screen prints its scores. The summary prints:
    - screens, valid (a non-empty tree that `fixGenerated` had nothing to fix in; for A2UI also no diagnostic but `actionNotRun`), screens with more than one filled button before polish, coloured nodes, kinds and leaves per screen, and containers per screen (rows, cards, grids);
    - copied example lines;
    - first content p50/p95 and completion p50/p95 in ms;
    - output tokens (hosted, from `.usage`).
- **`Package.swift`:** `// swift-tools-version: 6.1`, platform macOS 27, one executable target, Swift 6 language mode. Its dependencies:
  - the A2UI package, pinned by revision `07735d6a654ae3ba25951a8753ddd57b344b1169`, with the products `A2UISwiftCore` and `BasicCatalog`;
  - `https://github.com/ajevans99/swift-json-schema`, at the version the A2UI package resolves (0.13.x), as a direct dependency with the products `JSONSchema` and `OrderedJSON` (F10). `LayerCatalog` imports `JSONSchema`, and the importer and exporter import `OrderedJSON`.
- **`run.sh`** copies these into `Sources/ScreenBenchmarkHarness/App/`:
  - `Layer/Tree/*.swift` and `Layer/A2UI/*.swift`;
  - `Layer/Model/Design.swift`, `ShapeKind.swift`, and the projection files `Design.swift` now needs. That includes `Layer/Model/Projection/ScreenDrawing.swift` whenever it exists, whether Task 9 lands before or after this task (F10);
  - `Layer/Components/ComponentSpec.swift` and `Catalogue.swift`;
  - `Layer/Document/JSONValue.swift`;
  - `Layer/Sketch/PromptOverrides.swift`, `ScreenPrompt.swift`, `ScreenStream.swift` and `A2UIPrompt.swift`;
  - `Layer/Providers/HostedModelClient.swift` and `HostedProvider.swift`;
  - the stubs in `Tools/SketchBenchmarkHarness/Stubs.swift` and `Tools/Shared/`. `Tools/Shared/` gains a `SystemSymbol` stub (`resolve(_:)` and `placeholder`, which `A2UIIcons`, the importer and the exporter use) and whatever `HostedProvider.swift` needs (`ModelPreferences.serverURL(for:)`) (F10).

  Then it runs `swift run -c release --package-path Tools/ScreenBenchmarkHarness ScreenBenchmarkHarness "$@"`. A file that won't compile on macOS gets a stub in `Tools/Shared/`; no app file changes to suit the harness.

- [ ] **Step 1: Build it.** Run `Tools/ScreenBenchmarkHarness/run.sh check`. Expected: `harness ok: outline 1/1 valid, a2ui 1/1 valid`, and exit 0.

- [ ] **Step 2: Measure the on-device outline prompt.**
  - Run only while no other lane or `xcodebuild` is running, and record in the ledger that the machine was quiet (F17).
  - Run `run.sh outline 3` (24 screens).
  - The bar is today's `docs/benchmarks/screen-prompt.md` numbers:
    - valid 24/24;
    - no screen with more than one filled button after polish;
    - at most 5 coloured nodes;
    - at least 5 kinds per screen on average;
    - 5 to 14 leaves per screen on average.
  - If it misses, change the grammar or rules wording and run again, at most three rounds, recording each.
  - If indentation is what costs it, the compact grammar teaches only `row:` and `card:` and the report says so.

- [ ] **Step 3: Smoke-test the hosted modes.**
  - If `curl -s http://localhost:1234/v1/models` answers, run `run.sh hosted google/gemma-4-26b-a4b a2ui 1` and `… outline 1` and record both summaries as "smoke only".
  - Otherwise record "LM Studio not running".
  - The comparison that picks the default is plan 6's.

- [ ] **Step 4: Write the failing tests** in `ScreenPromptWordingTests`. Each literal is the measured text, pasted from the source after Step 2:
  - `theMeasuredOutlinePromptIsUnchanged`: `ScreenPrompt.instructions(.compact, for: "a settings screen for a podcast app")` equals the literal word for word, and so does `.full`.
  - `theA2UIPromptIsUnchanged`: `A2UIPrompt.instructions(for: "a settings screen for a podcast app")` equals its literal. Plan 6 measures it, and must change this pin when it changes the words.

- [ ] **Step 5: Run them.** Run `ScreenPromptWordingTests`. Expected: FAIL until the literals are in, then PASS. Then run the full unit suite. Expected: TEST SUCCEEDED.

- [ ] **Step 6: Record.**
  - `screen-prompt.md` gets a dated section "The outline (plan 3)" with every summary, the rounds, and the final wording's numbers beside today's.
  - `semantic-tree.md` gets an "After plan 3" column. It holds:
    - the on-device first content and completion p50/p95 in the generation row;
    - in the streaming row: 100% stable, one commit per update, and no layout on the main actor, naming `GenerationThroughTheReconcilerTests`.

- [ ] **Step 7: Commit.** `git add -A && git commit -m "Screen harness: a Swift package linking the A2UI SDK and the app's parsers, the on-device outline prompt measured, and both prompts pinned word for word"`

---

### Task 13: ScreenBlueprint deleted, and the plan's finish

**Lane:** A (waits for every other task)

**Files:**
- Delete: `Layer/Model/ScreenBlueprint.swift`
- Modify:
  - `Layer/Model/DesignStore.swift`: `setElements(_:on:)` appends only, and `DesignContent.setChildren(of:to:)` is deleted if nothing calls it;
  - its callers: `Layer/Intents/ElementIntents.swift`, `Layer/Voice/VoiceToolbox.swift`, `Layer/Canvas/ImagePlaygroundSupport.swift` and `Layer/Debug/VoiceDemo.swift`;
  - `Layer/Model/ScreenTidy.swift`: comments only ("where the outline's column root starts");
  - `Layer/Tree/LookWords.swift`: its doc comment ("Shared by `ScreenBlueprint` and the outline") names the outline, Siri and voice instead (F12).
- Modify (fallout):
  - under (f), every test file that passes `replacing:`: `PanelStepTests`, `UndoNameTests`, `CanvasDragWorkTests`, `VoiceToolsTests`, `LayerOrderTests`, `VoiceCallTests`, `CanvasDragLandingTests`, `MultiSelectionTests`, `CanvasHitTestTests`, `GroupTests` (:710), `LayersPanelTests`, `RotationTests`, `FormatPanelTests`, `ConcurrentEditTests`, `ScreenGenerationTests` and `SiriIntentsTests`;
  - `SiriIntentsTests`' suites "Screen blueprints" (struct `ScreenBlueprintTests`, renamed `WrittenScreenTests`, since the grep in Step 4 would find its name) and "Look words";
  - under (f), `OutlineTests.theBlueprintStillReadsItsLooks` (:198): the same assertions on the leaf of `Outline.parse("button: Go [bordered, 20pt]", isComplete: true)`. That is kind `.button`, text "Go", `.bordered`, font size 20, and no tint (F12);
  - `ComponentCatalogueTests` and `LayerTests/Goldens/ComponentKinds.txt` (h).
- Modify: `docs/benchmarks/semantic-tree.md` (the "After plan 3" column, completed)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new.
  - `setElements(_ elements: [DesignElement], on screenID: DesignScreen.ID) -> [ElementRef]` is today's `replacing: false`.
  - The deleted names are `ScreenBlueprint` (and its `Item`, `applyLook`, `kindWords`, `kind(named:)`, `layout(on:)`, `size(of:available:on:inRow:)`), `writeGenerated`, the blueprint's `withOnePrimaryAction`, and `setElements(_:on:replacing:)`.

- [ ] **Step 1: Port the remaining tests that use the blueprint (f).**
  - **"Screen blueprints"** becomes "Written screens", on `Outline.parse` and `TreeRules.laidOut` on the iPhone:
    - The reading cases assert what `shortcutsWrittenForTheBlueprintReadTheSame` (Task 2) asserts.
    - `laysOutTopToBottomInsideTheSafeArea` keeps its assertions: the first leaf's minY ≥ `safeTop`; no leaf overlaps the one above; the button's minX is 20 and its width 353.
    - `aRowSharesItsWidth` keeps its assertions: equal minY, `a.maxX < b.minX`, and `b.maxX <= 373`.
    - `nothingToLayOutIsNil` asserts a root with no children.
  - **"Look words":**
    - `controlsTakeTheirState` reads the same outline, with the same assertions on the laid-out leaves.
    - `aLookCanBeGivenToAnElementAlone` uses `LookWords.look(from:).apply(to:)`.
  - **The setups at `SiriIntentsTests` :616 (`DesignActionTests`), :917 (`ImagePlaygroundTests`) and :1175 (`MovingTests`)** put an outline's sections on the screen with `store.replaceChildren(of: .screen(id), with: Outline.parse(…, isComplete: true).children)`. Their assertions stay (F11).
  - **`ComponentCatalogueTests`:**
    - `ScreenBlueprint.kindWords` and `kind(named:)` become `LookWords`'.
    - The "in a blueprint" line becomes "in an outline: \<`NaturalSize.of` at width 353\> | in a row: \<at 170\> | at 40pt: \<…\>" (h).
    - "laid out" is the leaf's frame from `TreeRules.laidOut` of the one-line outline `"<written name>"` on the iPhone.
    - Re-record `ComponentKinds.txt` the way its file says, and check by eye that only those two lines per kind changed.

- [ ] **Step 2: Drop `replacing:`.**
  - Every `replacing: false` loses the argument.
  - Every `replacing: true` caller is checked: on a screen that is empty at that point, it loses the argument. Otherwise it becomes `replaceChildren(of:with:)` with `LayerNode(element:)`.
  - Record each in the ledger under (f).

- [ ] **Step 3: Delete** `ScreenBlueprint.swift` and the dead code it leaves. Run `xcodegen generate`. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify the plan's end state.**
  - `grep -rn "ScreenBlueprint\|writeGenerated\|blueprint(ofFinishedLinesIn\|itemCount" Layer LayerTests Tools` finds nothing, and neither does `grep -rnE "setElements\(.*replacing:" Layer LayerTests` (a bare `replacing:` would also match `wrapper(replacing:)`).
  - `grep -rn "withOnePrimaryAction" Layer` finds only `Outline`'s and its callers.
  - `grep -rn "parseAll" Layer` finds only the importer's own message parsing, behind its guarded decode (F1).
  - The full unit suite passes.
  - The UI suite fails nothing outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.
  - `Tools/ScreenBenchmarkHarness/run.sh check` passes.
  - `grep -rln "PROJECTION: deleted in plan 6" Layer` lists only:
    - `Layer/Model/Projection/` (plan 3's `Look+Element.swift` and `ScreenDrawing.swift` are there);
    - `DesignContent`, and the `keepGroupsSound` shim;
    - `DesignScreen.drawing` in `Design.swift`, and `AssetLibrary.templatePreview`. `PhoneScreenView.swift` is not among them (F18).
  - `grep -rln "PROJECTION: deleted in plan 6" LayerTests` lists only `LayerTests/Support/CodeOfElements.swift`.

- [ ] **Step 5: Measure.**
  - Run only while no other lane or `xcodebuild` is running, and record in the ledger that the machine was quiet (F17).
  - Run `StoreChangeBudgetTests` and `GenerationThroughTheReconcilerTests`.
  - Complete the "After plan 3" column: the store-change p95s, and the streaming row.
  - Record in the ledger, for plan 6's finish, the open spec §9 item (F20). Spec §9 says what can't be fixed in generated and imported trees is "reported in the import sheet or the generation's status", and plan 3 doesn't show those issues, such as clipping by the screen.
  - Record in the ledger the iPad checks plan 6's checklist must carry:
    - a hosted generation streaming on the device;
    - A2UI from Files and a paste;
    - Build Screen from Shortcuts;
    - a card's look;
    - a long title in a generated column.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "ScreenBlueprint removed: its grammar, writeGenerated and replacing a screen's elements wholesale are gone; every screen now arrives as the tree"`

- [ ] **Step 7: Clean up.**
  - Delete the lane B and lane C worktrees and branches once merged.
  - Delete their simulators: `xcrun simctl delete "Layer iPad Pro 11 (st3-lane-b)"` and `"Layer iPad Pro 11 (st3-lane-c)"`.
  - Delete their DerivedData, and the harness's `.build/` and copied `App/` folder.
