# The sketch-first semantic tree: design

Date: 2026-11-23. Status: written for the user's review. Branch: `feature/semantic-tree` (worktree
`.claude/worktrees/semantic-tree`, from main 8d00fc7).

Sources:
- the user's decision, written up as GitHub issue #3 ("Implement sketch-first semantic UI
  architecture with A2UI v1.0 integration (breaking refactor)");
- the ChatGPT conversation behind it (pasted into the session on 2026-11-23; quoted below as "the
  chat");
- the user's two review comments on Copilot's draft PR #4;
- the user's choice on 2026-11-23: **"go with B"**.

The research reports are in the main checkout, uncommitted, under
`reports/Semantic tree 2026-11-23/recon/`:
- `model-store-file.md`: today's model, store, undo and file format;
- `canvas-interaction.md`: rendering, selection, editing, panels, UI tests;
- `sketch-generation-code-intents.md`: recognition, generation, code export, Siri, voice;
- `a2ui-sdk.md`: the A2UI 1.0 protocol and the official Swift SDK at `v0.11.0+swift`.

## Intent

Layer is an iPad app where the Apple Pencil sketches interfaces and a finger edits them. Today
every design is one flat list of elements, each placed at an absolute frame. Groups exist as
pointers in that list. Layout exists only in three places, none of which the design keeps:
- the code export, which guesses rows from overlapping frames;
- `ScreenBlueprint`, a top-to-bottom stacker for generated screens;
- `ScreenTidy`, a one-column relayout.

The user wants Layer rebuilt around a **semantic component tree that keeps the geometry of the
sketch**. In the chat's words:
- "Sketch-to-UI remains Layer's primary interaction model."
- "The drawn geometry is an instruction about the design."
- "Recognize the structure the user intended instead of letting a generator impose a template."

The tree also has to serve the other paths. A sketch, a generated screen and an imported A2UI
screen should all produce the same structure. One deterministic layout engine lays it out, and
the export writes it as nested SwiftUI.

The chat ranks what to optimise for, in order:
1. Pencil latency.
2. Sketch interpretation accuracy.
3. Fidelity to the drawn layout.
4. Native iOS design conformance.
5. Reliability and deterministic output.
6. Richness of AI generation.

When two of these pull against each other, the higher one wins.

The user chose option B. A new nested `LayerNode` type replaces `DesignElement` everywhere. The
canvas, selection, rotation, groups, Layers panel, Format panel, Siri and voice are rebuilt on it,
and older `.layer` files stop opening.

## Goals

1. **One canonical tree.** Every screen holds a root `LayerNode`; the open canvas holds a list of
   them. Containers hold children directly. `DesignElement`, its `group` and `parent` pointers,
   `keepGroupsSound`'s list surgery, `ScreenBlueprint` and `ScreenTidy` are all gone when the
   branch merges. There are never two models of the same design.
2. **Layout containers.** A container lays its children out one of five ways:
   - free (positions as placed, which is today's behaviour);
   - a row;
   - a column;
   - a grid;
   - an overlay.

   Each node sizes itself to fit its content, fill the space, or a fixed size. Containers have
   spacing, padding, alignment and distribution. A card is a container with a look of its own.
3. **One deterministic layout engine.** It is a pure, side-effect-free function that resolves
   frames from the tree. It re-lays only the containers an edit touched. It works for sketches,
   generation, import, device changes and the user's own edits, and it never runs inside a SwiftUI
   view body.
4. **Sketches keep their intent.** Every node made from a sketch remembers:
   - its original bounds;
   - its position relative to the screen;
   - how confident the reading was and what decided it;
   - its placement intent: fixed, leading, trailing, centred or proportional.

   A **structure pass** after the pen rests finds rows, columns, grids and cards drawn around
   things. When it is confident it builds them. When it isn't, it keeps everything where it was
   and offers the interpretation. It never moves established content on its own.
5. **Whole-screen generation produces the same tree.**
   - The on-device model writes a compact indented outline.
   - Hosted models write A2UI 1.0 or the outline, whichever the benchmark shows works better.

   Both stream into the canvas through one reconciler that keeps stable IDs and never overwrites
   what the user changed. A whole generation is one undo step.
6. **A2UI 1.0 at the boundary.**
   - Layer imports A2UI 1.0 JSON through the official SDK: it parses, validates against a
     catalogue, resolves the component graph from `root`, maps each component, and reports a
     diagnostic for each part it can't bring in.
   - Layer exports A2UI for its own use (hosted edits, round-trip tests) and for sharing.
   - A2UI actions, function calls and RPC are never run.
   - A2UI is never in the per-stroke Pencil path or in the editor's rendering.
7. **SwiftUI export follows the tree.**
   - Rows and columns become `HStack` and `VStack`, grids become `Grid`, overlays become `ZStack`.
   - Cards become padded containers with a background, and controls become native views.
   - Free containers keep an absolute-position fallback.
   - The output compiles, and a check proves it.
8. **Nothing the app does today is lost.** That includes:
   - ink and drawings, the lasso, tap-to-add selection, groups and nesting;
   - layer order and the Layers panel;
   - move, resize and rotate (one thing or several), lock and hide;
   - undo and redo, including concurrent edits undoing on their own;
   - the Format panel and its typed and scrubbed numbers, the zoom ruler, and Squeeze to Talk;
   - voice and typed screen edits, Siri and Shortcuts;
   - iCloud package saving, thumbnails, sharing and the code panel.
9. **Measured performance.** Layer records a baseline on main before the change and compares
   after it, against the chat's budgets (see Performance). No improvement is claimed without a
   measurement.

## Non-goals

- Play Mode, links between screens, interactive previews, App Clips, a network or action runtime,
  data binding, and agent-run functions. The chat and the issue both exclude them; the model
  keeps a reserved, preserved place for interaction data, unused.
- Opening older `.layer` files. They are refused with a clear message, and there is no converter
  (the user's choice of B).
- The A2UI SwiftUI renderer (`A2UISwiftUI`, `BasicCatalogSwiftUI`) and the main-actor
  `MessageProcessor`. Layer uses only the SDK's plain, thread-safe parsing and validation.
- An A2UI Express compiler. Express exists only as a Python and Dart proposal, with no Swift
  implementation, so Layer won't invent one. The benchmark notes it as a follow-up.
- A backend, cloud service or vector database.
- Model calls on the structure pass. This round, the structure pass is rules only (see "My calls").

## Anti-goals (failure even if it works)

- Something the user drew or placed moves, unasked, by more than a few points. That covers
  inference, generation, a model's reinterpretation, and a device change of a free screen.
- A model call, or a trip through A2UI, on an ordinary stroke.
- An existing feature quietly stops working. Losing one is a bug unless this document names it.
- The flat list survives as a second model beside the tree. A temporary adapter during the
  branch is allowed only as described in "How the branch gets there", and must be gone before
  merge.
- Layout work in a SwiftUI `body`, or whole-tree layout on every edit.
- Generated SwiftUI that doesn't compile.

## Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, `@Observable`, Swift Testing and XCUITest,
  XcodeGen (`project.yml` → `xcodegen generate`).
- **macOS harnesses:** `Tools/SketchBenchmarkHarness`, `Tools/ScreenBenchmarkHarness` and
  `Tools/VoiceBenchmarkHarness` compile the app's own `Sketch/`, `Voice/` and model sources. The
  layout engine, the outline parser and the A2UI mapper must therefore build on macOS too: no
  UIKit, and text is measured with Core Text.
- **The A2UI package:** official `https://github.com/a2ui-project/a2ui`, pinned by **revision**
  `07735d6a654ae3ba25951a8753ddd57b344b1169`, which is tag `v0.11.0+swift` (`exact: "0.11.0"`
  may not resolve against that tag). Products: `A2UISwiftCore` and `BasicCatalog` only.
  - Its build-tool plugin needs Xcode's one-time "Trust & Enable".
  - Every `xcodebuild` the project documents or runs (scripts, CI notes, the test commands in
    plans) gains `-skipPackagePluginValidation`. It also gains `-skipMacroValidation` if
    swift-json-schema links a macro; check after the first resolve.
  - Xcode Cloud (its untracked workflow folder) needs the same. That is flagged to the user, not
    configured here.
- **Undo semantics stay.** Every step is a three-way, per-property revert of only its own
  changes, so concurrent edits (a drag during a generation, a voice command) undo on their own.
  Gestures, Format runs, voice commands and generations each stay one step, and history is
  capped at 50. See `model-store-file.md` §2.2.
- **Ink stays in PencilKit.** Unlocked drawings remain strokes on the document `PKCanvasView`,
  above everything, and ink stays in its own package files.
- **The performance counters stay meaningful.** The existing DEBUG counter tests (`CanvasWork`,
  `LayersPanelWork`, `ListWork`, `CodeWork`) are ported or replaced by equivalents that count
  the same work.
- **The sketch cascade keeps its rules and numbers:**
  - rules first, confidence-gated model escalation, a 4-second limit, then fallback;
  - top-1 accuracy of 87.8% with rules alone and 89.1% with the model;
  - the 156-fixture corpus;
  - the prompts' measured wording (`SketchHintTests`).

  No test lowers them.
- **Ids are stable.** A node's id survives edits, a kind change, reconciliation and saving. Ink
  file names, Siri entities, voice handles and the reading log all key on it.

## Approaches

### What the tree is (the user's choice)

- **A. Grow groups into layout containers.** Today's flat list, where each element names its
  group, becomes the tree's storage, and groups gain layouts and sizing. Rotation, the Layers
  panel, Siri and voice would mostly carry over, and old files would still open. I recommended
  this.
- **B. A new nested `LayerNode` type replaces `DesignElement` everywhere.** This is closest to
  the chat and the issue ("make the semantic component the primary representation", "eliminate
  the dual layout model", a clean schema break). It means rewriting the canvas, selection,
  rotation, groups and Siri on the new type, and old files stop opening.
  **The user chose B** ("go with B").
- **C. Keep Copilot's PR #4, a `LayerNode` shadow tree beside the flat list.** This was ruled out
  by the user's own review of the PR ("make one canonical model"). That PR also never compiled
  and conflicts with main.

### How the nested tree is held (my call)

- **Nested values with an index (chosen).** `LayerNode` is a value type whose `children` are
  `[LayerNode]`. The store keeps a derived index, rebuilt once per design version, mapping each
  id to its host, parent, path, depth, transform and effective lock and hide. Lookups are O(1)
  and edits copy one path.
  - This matches how SwiftUI and the code export think, and it keeps the value semantics today's
    undo relies on.
- **Normalised storage with nesting only in the API (rejected).** This is what A2UI does on the
  wire, with ids pointing at ids. It would make B the flat model again under another name.
- **Absolute frames on every node (rejected).** Moving or turning a container would mean
  rewriting every descendant, as groups do today. Parent-relative frames make a container move
  as one, and let the layout engine write local frames.

### How the branch gets there (my call)

- **Staged cutover with a temporary projection (chosen).**
  1. The tree and its engine are built and tested first, beside the old model.
  2. Then the store's stored value becomes the tree, and the tree is the only thing saved,
     undone or edited from that commit on. Code not yet moved reads and writes through a
     **computed projection**: a flat `DesignElement`-shaped view of the tree, where writes are
     converted straight back into tree edits.
  3. Each later step moves one area (canvas, panels, sketch, generation, Siri, voice) onto the
     tree and deletes what it no longer needs.
  4. The last step deletes the projection and `DesignElement`.

  The app builds and every test passes at each commit. The projection is exact, because
  containers translate and turn their children but never scale them: a node's absolute pose is
  its centre, its summed angle and its own size. The final review checks that the projection is
  gone.
- **One big rewrite (rejected).** The branch would stay red for days, and reviews couldn't see
  regressions.

## Decided by the user

- The model and the A2UI boundary:
  - "Go with B": a nested `LayerNode` replaces `DesignElement` everywhere.
  - Older `.layer` files stop opening.
  - The live editor uses no A2UI.
- From the chat and the issue (the user's own decisions):
  - Layer keeps PencilKit, `SketchAnalyzer`, `ComponentRule` and `RuleInterpreter`, the
    confidence-based `SketchEngine` with its 4-second limit and fallback, `HandwritingRecognizer`
    and `AppleIntelligenceInterpreter`.
  - Layer removes `ScreenBlueprint` and its prompt grammar, and `ScreenTidy`'s one-column
    assumptions. It also removes the flat list as the layout model and the old document decoders.
  - The code export is rewritten to emit nested structures. `DesignStore` is refactored for
    stable tree edits.
- The sketch paths:
  - Recognition writes straight into the semantic model, with no A2UI round trip.
  - A separate structure pass infers relationships after a gesture settles.
  - Model calls happen only for ambiguity, and return a constrained choice.
- The structure pass:
  - When it is confident, it creates the group. When it is ambiguous, it keeps the elements where
    they are and offers an interpretation.
  - "Never destroy the original sketch or rearrange established content merely because an AI
    interpretation changed."
- A2UI:
  - The catalogue is adopted for validation and interchange.
  - The official SDK (core and basic catalogue) is used at the import boundary.
  - Layer never runs A2UI actions or RPC, and never puts the A2UI renderer in the editor.
  - Express gets benchmarked first. The issue adds: "do not invent a Swift Express API".
- Generation:
  - Each model keeps its own format.
  - Every generator yields the same semantic tree.
  - Whole-screen generation stays a secondary path.
- The design system has four layers:
  1. Native components first.
  2. Layer's tokens.
  3. The user's overrides, which aren't errors.
  4. AI suggestions, only for real violations.
- Performance targets, which are budgets to measure against rather than claims:
  - recognition p95 under 100 ms after the gesture completes;
  - a simple layout update p95 under 16 ms;
  - 100% stable IDs for unaffected nodes;
  - model help is asynchronous and falls back deterministically;
  - no unexplained layout movement.
- Excluded from this work: Play Mode, action wiring, agent functions and data binding.
- The first milestone: sketch a nested card or a two-column layout, see the hierarchy at once,
  and export equivalent SwiftUI without losing the composition.

## The design

### 1. The document

```swift
struct DesignContent {            // design.json "content", version 4
    var screens: [DesignScreen]   // back to front
    var canvas: [LayerNode]       // things on the open canvas, back to front; each has `scale`
    var title: String?
    var settings: CanvasSettings  // today's CanvasSettings, unchanged in meaning
    var unknownKeys: UnknownKeys
}

struct DesignScreen {             // as today, plus a root
    var id, name, origin, scale, deviceID, isLocked, unknownKeys
    var root: LayerNode           // kind .group, frame = device bounds, sizing fixed
}
```

- A screen's root is a container the size of the device. Its layout is `free` for a sketched
  screen and a column for a generated one. The screen itself is what gets selected, named,
  locked and moved: its root has no row of its own in the Layers panel and can't be deleted.
  Its layout is edited in the screen's Format panel.
- The open canvas is a list of top-level nodes. Each carries its own `scale` (canvas points per
  own point), as floating elements do today. Their descendants use their coordinates.
- Sticky notes and drawings live only on the canvas, never on a screen (as today).
- Drawings are only top-level canvas nodes. They are never inside containers, never arranged,
  and always drawn above everything by PencilKit (as today).

### 2. `LayerNode`

```swift
struct LayerNode: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var kind: ElementKind          // 16 leaf kinds as today; .group and the new .card are containers
    var children: [LayerNode]      // containers only; one order: back to front, and the layout order
                                   // in rows, columns and grids (see My calls 15)
    var layout: Layout?            // containers only (nil reads as .free)
    var width: Sizing              // .fit | .fill(weight) | .fixed; min/max optional
    var height: Sizing
    var frame: CGRect              // in the PARENT's space (its top-left is 0,0), upright
    var rotation: Double?          // degrees clockwise about the frame's centre; nil = upright
    var scale: CGFloat?            // top-level canvas nodes only
    var content: Content           // text, symbol, shape, imageID, isOn, value, buttonLook; ink kept apart
    var style: Style               // tint, font size and weight, text colour, alignment, corner radius,
                                   // opacity, border, shadow; a card's fill
    var name: String?
    var isLocked: Bool
    var isHidden: Bool
    var accessibility: Accessibility?   // label and hint overrides; nil = derived from content
    var sketch: SketchIntent?           // see §5
    var source: Source?                 // how it came to be, and its key for reconciliation (§6)
    var interaction: JSONValue?         // reserved for later (Play Mode etc.); kept, never read
    var unknownKeys: UnknownKeys
}
```

**Kinds.** The 16 leaf kinds keep their catalogue specs (`Catalogue`/`ComponentSpec`): sizes,
looks, traits, sketch hints and written names. There are two container kinds:
- `.group`: a container with no look of its own. It is today's group, generalised.
- `.card`: a container with a look. It has a fill of the grouped secondary background, a 16 pt
  radius and 16 pt padding, and a column inside it by default.

A node is a container exactly when its kind is one of these two.

**Layout.**

```swift
enum Layout {
    case free                       // children keep their frames
    case stack(Stack)               // a row or a column
    case grid(Grid)                 // `columns` equal columns, filled row by row
    case overlay(Alignment)         // children on top of each other, aligned
}
struct Stack { axis (horizontal|vertical); spacing; alignment (leading|centre|trailing|fill);
               justify (start|centre|end|spaceBetween|spaceAround|spaceEvenly) }
struct Grid  { columns 1...12; columnSpacing; rowSpacing; alignment (nine-point) }
// every container also has padding (four edges)
```

The vocabulary is A2UI's (`Row`, `Column`, `justify`, `align`, `weight`) plus a grid and an
overlay, so imports and exports map one to one.

**Sizing.**
- `fit` is the node's natural size: measured text, a control's native size, or for a container
  its content plus padding.
- `fill(weight)` shares the space left in a row or column, in proportion to weight.
- `fixed` is the node's `frame` size.

Each axis may have a minimum and a maximum. In a `free` parent every child behaves as fixed,
except that a container sized to fit still hugs its own content.

**Frames.**
- `frame` is always in the parent's space.
- Under a `free` parent it is the truth, set by the user, a sketch or an import.
- Under any other layout the engine writes it: it is the resolved frame, a saved snapshot of
  derived data. The user changes it through sizing, layout and order, never directly.

### 3. Geometry and transforms

- A node's transform to its host's space is its ancestors' translations and rotations, composed.
  Each container turns about its own frame's centre. Containers never scale their children.
- The host is the screen's placement (origin, scale), or, on the canvas, the top-level node's
  scale. Everything that needs canvas or view points reads them from the store's index:
  hit-testing, outlines, snapping, guides, the lasso, the popover, voice pictures and Siri
  layout JSON.
- **A turned container turns its whole subtree.** This is SwiftUI's `rotationEffect`: it doesn't
  change layout, and children keep their own local frames and angles.
  - Today, turning a group writes the turn into every member. With this tree, turning a group
    sets only the group's angle. The result on screen is the same.
  - Turning several selected things still turns each one about the shared pivot, as
    `TurnSession` does today. It works in host coordinates and writes each node's local frame
    and angle through its parent's inverse transform.
- **Free containers sized to fit hug their content.** After any change, a free container whose
  width or height is `fit` takes the box round its children's turned shapes as its frame, and its
  children are shifted so that nothing moves on screen. This replaces `fitGroupBoxes`.

### 4. The layout engine

`LayoutEngine` is a pure function over values. It is nonisolated and `Sendable`, and builds on
iOS and macOS. Given a container and the size proposed to it, it returns the container's size and
each child's frame, recursively.

- **Measure, then place.** This is SwiftUI's two passes.
  - Fixed children take their size first. Fitting children take their natural size, clamped to
    their minimum and maximum. Filling children share what is left by weight.
  - Cross-axis alignment uses `fill` to stretch.
  - `justify` spreads any leftover space only when no child fills.
  - Grids use equal columns and rows as tall as their tallest cell.
  - An overlay aligns every child in the container. Fitting containers take the largest child
    plus padding.
- **Natural sizes:**
  - Controls take their native sizes from the catalogue: a button 50 pt tall, a text field 44, a
    toggle 51 × 31. Kinds that `runsAcross` fill the width of a column.
  - Text is measured with Core Text, at its font size and weight, at Dynamic Type's default size,
    wrapping to the width it is given.
  - A text-measurement cache, keyed by the string, font and width, keeps repeat layouts cheap.
- **The screen root:**
  - A free root lays nothing out.
  - A column root is inset by the device's safe areas plus a margin: 20 on a phone, 32 on a
    tablet, 48 on a desktop. On a desktop its readable width is limited to 1080 and centred.
    These are `ScreenTidy`'s numbers, kept.
- **When it runs:** inside the store's change, after the structure rules (§8), on **dirty
  containers only**. A container is dirty when its own layout-relevant fields or any child's
  changed, or when the size proposed to it changed. The dirtiness travels up while a parent's size
  depends on the child.
  - Unchanged subtrees reuse their last result. Each entry is remembered by the container's value
    and the proposed size.
  - Whole generated or imported trees are laid out off the main actor before they are committed,
    so the commit finds nothing dirty.
- **Diagnostics, not corrections.** The engine reports:
  - children that overflow a container that can't grow;
  - text that doesn't fit its width;
  - an item clipped by its screen;
  - controls smaller than 44 pt.

  The validator (§9) acts on these only for generated and imported trees. It never corrects
  what the user authored.

### 5. The sketch path

The fast path is unchanged up to the reading: clustering, observation, rules, handwriting, a
model for close calls within 4 seconds, and fallback. What changes is where the reading lands
and what it remembers.

- **Where it lands.** The deepest visible, unlocked container under the sketch's centre on the
  screen:
  - **A free container (most of the time):** the node goes at the frame
    `ElementLayout.sketched` gives today. That covers the kind's standard size, centring, two
    columns, text after a neighbour, and the row, rhythm and edge snapping. Its neighbours are
    its new siblings.
  - **A row, column or grid:** the node is inserted at the place nearest to where it was drawn.
  - **No container:** the screen root, as today.
  - **Off a screen:** the canvas, as today.
- **What it remembers** (`SketchIntent`, saved):
  - `originalBounds`: the sketch's box in host points;
  - `normalizedBounds`: the sketch's box relative to the screen;
  - `confidence`: the reading's score;
  - `decidedBy`: rules, handwriting, model or asked;
  - `placement`: one of
    - `leading`, when it starts within the left margin zone;
    - `trailing`, likewise on the right;
    - `centred`, when its centre is within 6% of the screen's width of the middle;
    - `proportional`, when it spans 90% or more of the width;
    - `fixed` otherwise.

  "Did you mean" now re-lays out from `originalBounds` on the node, not from the 8-second
  suggestion alone. The offer still lasts 8 seconds.
- **Placement intent on device changes.** When a free screen changes device, each sketched node
  keeps its intent:
  - leading keeps its left inset, and trailing its right inset;
  - centred stays centred;
  - proportional scales its x and width with the screen's width;
  - fixed stays put.

  Column roots simply re-lay. This replaces `ScreenTidy.frames(from:)`, and now applies however
  the device changes: the panel, Siri and voice alike. Today only voice reflows.
- **The structure pass** (`StructureInference`) is pure and deterministic, with thresholds in
  one `StructureConventions`.
  - **When:** once the pen rests, after a conversion batch settles.
  - **Where:** only the container that received new nodes, looking only at the new nodes'
    neighbourhood.
  - **What it looks for:**
    - **A card drawn round things.** A big enclosure drawn round one or more existing siblings,
      each at least 90% inside, reads as a card holding them, ranked with today's
      image/button/text-field candidates. The rules add the card reading only when something is
      enclosed. The enclosed things keep their absolute places, and the card is a free
      container. If the enclosed things form a confident column, the card's inside becomes a
      column instead.
    - **A row.** Two or more siblings qualify when:
      - their centres share a line within 6 pt, or their tops or bottoms align within 4 pt;
      - their heights are within 2× of each other;
      - each gap is at most 32 pt;
      - nothing else lies between them.

      The row's spacing is the median gap, rounded to the rhythm (8, 12, 16, 24 or 32), and its
      alignment is whichever edges line up.
    - **A column.** Three or more siblings qualify when:
      - they share a leading, centre or trailing edge within 4 pt;
      - their gaps are regular, varying by 4 pt or less.
    - **A grid.** It needs at least 2 rows and 2 columns, where:
      - row tops align within 4 pt;
      - column leading edges align within 4 pt;
      - cell sizes are within 20% of each other.
  - **Confidence** is computed from the alignment error, the regularity of the gaps and how
    similar the sizes are, between 0 and 1.
    - At 0.8 or more, it is applied automatically, but only if no node would move by more than
      8 pt. It joins the conversion's undo step.
    - Between 0.5 and 0.8, or when something would move further, it is **offered**. The pill
      works like "Did you mean": "Make a row?" lasts 8 seconds, and accepting is its own undo
      step.
    - Below 0.5, nothing happens.
  - **It never touches:**
    - locked, hidden or drawing nodes;
    - a container the user made;
    - nodes the user ungrouped or declined. Each is marked with
      `SketchIntent.structureDeclined`, so the pass never fights the user.
- Voice's "tidy up" runs the structure pass over the whole screen with a lower bar for
  automatic changes, and the engine lays out the result. One undo step. This replaces
  `ScreenTidy`.

### 6. Generation, reconciliation and A2UI

**The outline.** This is the on-device format, and the hosted fallback. It replaces
`ScreenBlueprint`'s grammar and parser:

```
column:                          a container's children are indented by two spaces
  title: Profile
  row:
    avatar
    text: Alex Tan [bold]
  card:
    text: About me
    body: Designing better experiences.
  grid 2:
    text: 24 Projects
    text: 8 Teams
  button: Edit profile
row: text: Wi-Fi | toggle [on]    the one-line row stays, so existing Shortcuts keep working
```

- What carries over from today:
  - kinds and their written names;
  - look words in brackets;
  - tolerant parsing: `;` as a newline, code fences and headings ignored, a line with no kind
    read as text;
  - one primary action.
- Top level is the screen root's column, and a blank line starts a new section.
- The parser is streaming: each finished line extends the tree.
- Each node's reconciliation key is its path of `(kind, ordinal)`.
- The prompt keeps today's rules and example library, rewritten in the outline. Its wording is
  measured again with `ScreenBenchmarkHarness` and pinned by a test, as today's prompt is.

**Hosted generation.** Both formats are built:
- A2UI 1.0: createSurface, then updateComponents, written as JSON lines, with Layer's catalogue
  (below). The key is the component id.
- The outline.

The benchmark picks the default. It runs on macOS 27.2 with a hosted model, and compares output
tokens, time to first content, time to completion, and how often the output is valid. A2UI is
the default unless it is worse on validity, or more than 25% slower to first content.

**Reconciliation (`TreeReconciler`).** There is one reconciler for every streamed or repeated
write.
- It keeps a map from each key to a node id and to the value last written.
- Nodes still as they were written are updated. Nodes the user changed since are left alone.
- New keys are added, and surplus written nodes are removed unless the user changed them.
- Hand-added nodes are never touched.
- Each update lays out off the main actor, then commits once. The whole generation is one undo
  step.

This replaces `writeGenerated`'s index matching and `setElements(replacing: true)`.
- Generation still always makes a new screen, as today.
- Siri's Build Screen rebuilds an existing screen through the same reconciler, instead of
  replacing every element.

**A2UI import** (`A2UIImporter`, off the main actor, using only `Sendable` SDK APIs):
1. **Parse:** `AgentToRendererMessage.parseAll(from:protocolVersion: .v10)`, which takes one
   message, an array or `{messages}`. Anything whose `version` isn't `"1.0"` is rejected.
2. **Per surface:** keep components by id, last write wins. Duplicates within one message are a
   diagnostic. A surface's catalogue comes from `createSurface.catalogId` or the component's
   `@catalogId`; a component with neither is a diagnostic.
3. **Validate** each component with `PayloadValidator` (strict, v1.0) against the Basic Catalog
   or Layer's catalogue. Each failure becomes a diagnostic with its JSON path. Layer doesn't stop
   at the first one.
4. **Resolve the graph from `root`** with Layer's own walker, which follows the child slots that
   `GraphTopologyValidator.extractReferences` reports. It handles `children`, `child`, Tabs'
   `tabs[].child` and Modal's `trigger`/`content`. Cycles, unresolved ids, ids that nothing
   reaches, a missing root and depth over 50 are all diagnostics.
5. **Map** each component to nodes (table below):
   - `@accessibility.label` becomes the node's accessibility label.
   - A `@path` binding reads the surface's data model if one was sent. Otherwise it becomes
     placeholder text, with a diagnostic.
   - A template `children` expands over its data-model array if present, else to one item with a
     diagnostic.
   - `@call` values and every `action` are never evaluated or run. A button with an action gets a
     diagnostic: "its action isn't run in Layer".
6. **Commit:** lay out off the main actor, then commit as a new screen in one undo step. A sheet
   then lists anything not brought in, grouped by reason.

| A2UI | Layer |
|---|---|
| Column, Row | group with a column or row; `justify`, `align` and each child's `weight` map directly |
| List | group with a column or row (by `direction`); diagnostic "scrolls in an app" |
| Card | card |
| Text | title when its Markdown is a `#` or `##` heading, body when longer than one line, else text; `variant: caption` becomes secondary text colour; Markdown markers are stripped |
| Image | image; `variant: avatar` becomes avatar; `variant: icon` becomes symbol |
| Icon | symbol, through a fixed table from A2UI icon names to SF Symbols, falling back to Layer's symbol fallbacks |
| Button | button; its child Text gives the words; `primary`, `default` and `borderless` become filled, bordered and plain |
| TextField | text field (its label or placeholder gives the words) |
| CheckBox | row of a checkbox and its label |
| ChoicePicker | column of radio or checkbox rows |
| Slider | progress; diagnostic |
| DateTimeInput | text field; diagnostic |
| Divider | divider; a vertical divider gets a diagnostic |
| Tabs | the first tab's content; diagnostic |
| Modal | the trigger only; diagnostic |
| Video, AudioPlayer | image placeholder; diagnostic |
| Layer's catalogue: `LayerGrid`, `LayerOverlay`, `LayerFree`, `LayerToggle`, `LayerRadio`, `LayerProgress`, `LayerSymbol`, `LayerShape` | the matching node |

**Layer's catalogue** (catalogue id `urn:layer:a2ui:catalog:1`) extends the Basic Catalog with
the kinds A2UI lacks, using the SDK's `derive(id:components:functions:)`.
- Its schemas declare `children`/`child` as `ChildList`/`Child`, so reference extraction finds
  them.
- Layer's own styling travels in `@metadata.extensions.layer`: colours, sizes, radius, a free
  child's frame and rotation. This makes Layer → A2UI → Layer lossless for Layer's own exports.
  Other agents' A2UI simply gets Layer's defaults.

**Where A2UI comes in and goes out:**
- In:
  - dropping or pasting A2UI JSON (a file or text) onto the canvas;
  - "Import A2UI…" in the top bar's add menu (a Files picker);
  - Siri's Build Screen, which takes the outline or A2UI JSON.
- Out:
  - a per-screen "A2UI JSON" item in the Share menu;
  - Layer's own uses: telling a hosted model a screen, and round-trip tests.

**Typed screen edits and voice** stay on the voice agent's tools, which now work on the tree (see
§11). They are not regenerations.

### 7. SwiftUI export

`SwiftUICodeGenerator` walks the tree:

| Node | Export |
|---|---|
| Row or column | `HStack`/`VStack(alignment:spacing:)`; padding as `.padding`; `justify` as `Spacer()`s; fill as `.frame(maxWidth/maxHeight: .infinity)`; fixed as `.frame(width:height:)` |
| Grid | `Grid(horizontalSpacing:verticalSpacing:)` with `GridRow`s |
| Overlay | `ZStack(alignment:)` |
| Card | its layout's stack, `.padding(16)`, `.background(.background.secondary, in: .rect(cornerRadius: 16))` |
| Free container | **Structure:** today's reading-order inference, its children read at their host-space frames and angles. Rows by vertical overlap become `HStack`s, gaps become `.padding(.top, …)`, the side margin is inferred, and the numbers stay literal. A free group inside it is transparent: its members join the inference. A card or a laid-out container is one item, and its own code follows this table. Below the screen root, the inference runs inside the container's content box, with no safe areas and no bottom `Spacer()`, framed `.frame(width:height:alignment: .topLeading)`. **Exact positions:** `ZStack(alignment: .topLeading)` with each child `.frame(width:height:)`, `.rotationEffect` and `.offset(x:y:)`, the absolute-position fallback. |
| Free screen root | **Structure:** today's reading-order inference, as above, with today's safe areas and bottom `Spacer()`. A sketched screen of leaves exports byte for byte as today. **Exact positions:** today's exact-positions output. |
| Column screen root | a `VStack` that respects the safe area, with the root's padding |
| Leaves | today's native views and styling, `.rotationEffect`, names as comments |

`CodeSettings.layout` becomes **Structure** (the default, which follows the tree) or **Exact
positions** (everything absolute, as today's mode).
- In Structure, free containers, sketched screens included, are written by today's reading-order
  inference, so a sketched screen's code doesn't regress. Laid-out containers, cards and column
  roots follow the table and use the design's token names. (Amended 2026-11-23 by plan 3's call
  12, the controller's ruling for the user's priority of structural design on sketched screens.)
- Hidden nodes and drawings are left out, and so is the open canvas.
- View names stay unique.
- Share, the code panel and Siri still produce the same code.

**It must compile.** `scripts/check-generated-swiftui.sh` generates code for every fixture design
(`LayerTests/Fixtures/Designs/*.layer`) and runs
`xcrun swiftc -typecheck -sdk iphonesimulator -target arm64-apple-ios27.0-simulator` on each file.
Every plan's verification step runs it. Golden files in `LayerTests/Goldens/Code/` pin the
output.

### 8. The store

`DesignStore` stays the one `@Observable` owner of `content`, with the same change pipeline,
edits and history. What changes:

- **Verbs on the tree:**
  - `add(_:to:at:)` and `move(_:to:at:)` (reparent within or across hosts, keeping the place on
    screen unless it lands in a laid-out container);
  - `update(_:_:)` (any field but id and structure);
  - `wrap(_:in:layout:)` (Group, and Group as Row, Column, Grid or Card);
  - `unwrap(_:)` (Ungroup) and `setLayout(_:_:)`;
  - `delete`, `duplicate`, `arrange` and `rehost`;
  - `position`, `resize` and turn sessions;
  - `reconcile(_:on:with:)` and `importScreen(_:)`.

  The many callers of today's `update(ref) { $0.frame = … }` go through the index for host↔local
  conversion.
- **The rules after every change, undo, redo and read** replace `keepGroupsSound`. They run once,
  in the same change:
  1. **Structure:**
     - drawings only at the canvas's top level;
     - sticky notes only on the canvas;
     - an empty `.group` is removed;
     - a free `.group` of one child dissolves into its parent, handing down its lock and hide;
     - cards, and groups with a row, column, grid or overlay layout, persist with any number of
       children, because a row of one is still a row;
     - nothing nests deeper than 32;
     - a design holds at most 5,000 nodes.
  2. **Layout of dirty containers** (§4).
  3. **Free containers sized to fit** take their content's box (§3).
- **Undo.** The three-way revert generalises from "elements in a host's list" to "nodes in a
  parent's list".
  - Each node is compared as a record: its fields without children, its parent's id and the id
    of the sibling before it. This is today's algorithm, keyed by parent instead of by host.
  - The revert lists name every `LayerNode` field. A test fails if a field is missing, because a
    missing field makes undo restore the whole node.
  - Steps, edits, held edits, `putOnTop`, `markNeedsSaving`, `Touched`, `onlyScreen(changedBy:)`
    and the cap of 50 all stay.
- **The index**, built lazily once per design version, maps each id to:
  - its host, parent and sibling index;
  - its path and depth;
  - its transform to the host, and its turned shape in canvas points;
  - its effective lock and hide.

  It replaces `Views`, `index`, `keptTargets` and the group walks.
- **Observation** stays on the whole design. Rendering is localised by views that compare node
  values (`Equatable`), so an edit to one node re-evaluates only the views on its path. A DEBUG
  counter, `CanvasWork.nodeViewsBuilt`, pins this.

### 9. Validation and native conformance

`TreeValidator` is pure. It checks:
- every kind is known, and children are allowed (leaves have none, drawings only at the canvas
  top level);
- depth is at most 32 and count at most 5,000;
- no geometry is non-finite or negative;
- clipping by the screen;
- text of 11 pt or more;
- controls of 44 pt or more;
- no action or interaction data runs (it is never read).

How each source is treated:
- **Generated and imported trees** are validated before they are committed. Fixable problems are
  fixed, such as clamping a control to 44 pt or wrapping text. The rest are reported in the
  import sheet or the generation's status.
- **User-authored nodes** are never corrected. The checks are available to tests and the
  diagnostics log. This round has no on-canvas issue list (see Left to the builder).

Styling follows the four layers:
1. Native SwiftUI controls and semantic colours and materials in the export.
2. Layer's tokens: the catalogue's sizes and radii, the 20/32/48 margins, the 8/12/16/24/32
   rhythm, and the card's look.
3. The user's overrides, which are kept and exported.
4. Generation never sets colours unless asked. Today's prompt rule stays.

### 10. Canvas, selection and panels on the tree

The behaviours listed in `canvas-interaction.md` §6 are kept unless a line below changes them.

- **Rendering.** Each screen draws its root through a recursive node view:
  - frame, then rotate, then offset, in the parent's space;
  - a card draws its look under its children;
  - children draw in order;
  - nothing clips.

  The canvas's top-level nodes draw above all screens, as today. Ink stays on PencilKit, and
  locked drawings use `InkPicture`.
- **Hit-testing and selection.** These are today's rules exactly, with "group" read as **any
  container**:
  - a tap picks the outermost container not yet entered, and a double-tap goes in;
  - a tap adds, a tap on a selected thing removes, and only empty canvas clears;
  - the 8 pt near-miss rule, the resting finger, the lasso and box coverage (a container is
    picked whole by its box), the screen's empty area and the name strip.

  The selection holds node ids and screen ids.
- **Moving something in a free container** works as today: dragging, snapping to guides or the
  grid, the screen holding the drag raised, and a drop on another host rehosting it there.
  Dragging a member of a free group out of the group's box doesn't take it out of the group: the
  box grows, as today.
- **Moving something in a row, column or grid** (Figma's convention):
  - A drag shows an insertion line within its container, and dropping reorders it there.
  - Dropping it outside the container takes it out. It lands on the host's root at the drop
    point, free, or inside another row, column or grid if that container shows an insertion line
    under the finger.
  - Snapping applies only to free placement.
- **Resizing:**
  - In a free parent, as today: corner handles in the node's own axes, minimum sizes from the
    catalogue, and turned resize.
  - In a laid-out parent, a handle sets `fixed` on the axis it changes.
  - A container in a free parent resizes as a group does today. For a free container, its
    children scale about its box, with text sizes and angles kept. A laid-out container instead
    becomes `fixed` and its children re-lay.
- **Rotating:**
  - The knob, twist and Rotation field work as today.
  - A container turns as a whole: its angle is set, and its subtree goes with it.
  - Several things turn about the fixed pivot as today (§3).
  - Laid-out children can be turned too, which is visual only, as in SwiftUI.
- **Group and ungroup:**
  - **Group** (⌘⌥G) wraps the selected siblings in a free `.group`, in the frontmost one's
    slot, and nothing moves.
  - The popover's Group button gains a menu: **Group**, **Row**, **Column**, **Grid** and
    **Card**. Row, Column and Grid lay the members out in their reading order: left to right,
    top to bottom, or row by row. The user asked for that, so things may move.
  - **Ungroup** puts the children in the container's slot in its parent with their places on
    screen kept, baking the container's turn into each child. If the parent is a row, column or
    grid, they join it at that slot.
  - The selection must share one parent, which replaces today's "one host, same group".
- **Lock, hide, arrange, align, distribute, duplicate and delete** keep today's rules:
  - an effective flag is the node's own or any ancestor's;
  - Unlock also unlocks its locked ancestors (Ruling D);
  - arranging steps past one sibling;
  - drawings stay on top;
  - a deleted container takes its contents;
  - a duplicate is offset by 16 and placed just in front of the original.

  Align and distribute apply in free parents only. In a laid-out parent the alignment controls
  edit the container's alignment instead.
- **The Format panel:**
  - **Containers and screens get a Layout section:**
    - a picker (Free, Row, Column, Grid, Overlay);
    - spacing, padding, alignment and distribution (the A2UI words, said plainly: Start, Centre,
      End, Space Between…);
    - columns, for a grid.
  - **Children of a row, column or grid get Width and Height sizing:** Fit, Fill or Fixed, with
    the number when fixed.
  - **A card** gets its fill.

  The typed-number rules (commit on Return, on leaving the field, or when the field goes), the
  scrubbing and the ruler stay as they are. X and Y are disabled for laid-out children.
- **The Layers panel:**
  - It is built from the tree directly, rather than from today's row tree, which shares the
    `LayerNode` name and is retired.
  - Rows show each container's layout with an icon for row, column, grid, overlay, card or group.
  - Dragging rows moves nodes among containers, with the same refusals as today: locked things,
    other hosts, a container into itself, and drawings. The Drawings section stays.
  - The cached-row counters stay meaningful.
- **Thumbnails and sharing** draw through the same views as the canvas.

### 11. Siri, Shortcuts and voice

**Siri and Shortcuts.**
- Entity ids keep their form, `design|host|uuid`.
- Queries and entities still show leaves only (today's rule that Siri sees members, not groups).
- **Get Design Layout**'s JSON gains the tree: each node lists its children, layout and sizing,
  with frames in screen points for screen nodes and canvas points for canvas nodes. It now
  includes rotation too.
- **Build Screen** takes the outline or A2UI JSON, and rebuilds through the reconciler.
- **Add Element** and **Move Element** work in screen points as today. On a laid-out child, Move
  Element moves it out of its container, following the drag rule.

**Voice.**
- The canvas picture lists nodes in reading order, indented by nesting. Containers get handles
  and their layout in words.
- Four tools are new:
  - `groupElements(handles, as: group|row|column|grid|card)`;
  - `setLayout(handle, layout, spacing)`;
  - `ungroup(handle)`;
  - `reorder(element, before|after, target)`.
- `moveElement` on a laid-out child answers with a line telling the model to use reorder, or to
  say where to take it out to.
- `tidyScreen` runs the structure pass (§5).
- `changeScreenDevice` reflows through the engine and placement intents.
- Typed screen edits, Squeeze to Talk, corrections and scoping are unchanged.

### 12. The file: version 4

- **Package parts** are as today:
  - `design.json`;
  - `ink/<node-uuid>` for each drawing;
  - `images/<uuid>`;
  - `QuickLook/Thumbnail.jpg`;
  - unknown parts kept.

  Incremental saving is unchanged: byte-equal parts keep their FileWrappers.
- **`design.json`** is version 4, with sorted keys. The content is nested:
  - `screens[].root` holds nodes with `children`;
  - `canvas` holds the canvas's top-level nodes.

  Unknown keys on nodes, screens and settings are preserved, as are nodes of an unknown kind,
  whose raw JSON is kept at their place.
- **Versions below 4** throw `ReadError.olderVersion`: "This design was made by an earlier
  version of Layer and can't be opened by this one." The old v1–v3 readers, `drawing.data`
  adoption and the v2 shapes are deleted.
- **Versions above 4** still throw today's "Update Layer" error.
- **Siri's and Spotlight's lightweight reader** skips a file with that error. It doesn't crash,
  and doesn't list the file as empty.
- **The thumbnail extension** is unchanged: it shows the JPEG the app writes.

### 13. Performance

A baseline is recorded on main before the store changes. The same measurements run at the end, in
`docs/benchmarks/semantic-tree.md`:

| What | How | Budget |
|---|---|---|
| Reading after the pen rests (rules path, no model) | `SketchBenchmark` timings over the 156 fixtures, plus the conversion including the structure pass, in a unit benchmark | p95 under 100 ms |
| Layout of one edit on a 100-node screen | unit benchmark of the store change: move, resize, text edit, add to a row | p95 under 16 ms in the simulator; checked on the iPad |
| A drag frame | counters: only the dragged node is written, only views on its path are rebuilt, and no layout runs outside dirty containers | today's `CanvasDragWorkTests` numbers or better |
| Streaming generation | ids of unaffected nodes are stable across updates; one commit per update; layout off the main actor | 100% stable |
| Generation tokens and time to first content | `ScreenBenchmarkHarness` on macOS (on-device outline; hosted A2UI and outline) | recorded, and the hosted default chosen from them |
| Canvas workout | `CanvasBenchmarkUITests.testCanvasWorkout` (CPU, memory, clock) | no worse than baseline by more than 5% |

### 14. Custom device frames and design tokens (added 2026-11-23)

The user asked on 2026-11-23: "support custom device frame components as well for the design
tokens". I proposed the design below to the user, who may correct it.

- **Custom device frames.** `DeviceFrame` becomes data that can be stored. Today's 9 built-in
  frames stay. A design also holds its own frames, in its settings, saved in the version-4 file:
  - `id` (`custom-<uuid>`) and name;
  - size in points, and corner radius;
  - safe-area insets: top, bottom, leading and trailing;
  - whether it has a status bar, an island and a home indicator;
  - family: phone, tablet, desktop, watch or other.

  A screen's `deviceID` resolves against the built-ins plus the design's own frames. An unknown
  id falls back to the iPhone, as today.
- **How to make one:** "Custom size…" in the device picker, or a frame made from a selected
  screen's current size. Custom frames appear in the device picker and the asset library's
  Frames tab.
- **Device tokens.** Every frame, built-in or custom, carries layout tokens:
  - `margin`: phone 20, tablet 32, desktop 48, watch 8, other 20;
  - `maxContentWidth`: desktop 1080, otherwise none.

  The rules pad a column screen from these tokens and its safe areas, instead of fixed numbers.
  Device changes reflow with them.
- **Design tokens.** Each design has one editable `DesignTokens` value. Its defaults are
  today's numbers, so nothing changes visually:
  - rhythm 8, 12, 16, 24, 32;
  - corner radii: small 8, medium 12, large 16;
  - card: padding 16, radius 16, fill `RGBColor(hex: 0xF2F2F7)`;
  - text sizes: title 28, body 15, text 17.
- **Who uses the tokens.** The engine's defaults, the structure pass's rhythm, the outline's and
  importer's starting spacing, and the validator all read the tokens instead of constants. No
  model ever picks a number.
- **Export.** The SwiftUI export writes a `DesignTokens.swift` file with the design's tokens and
  the margins of the screens' devices. The views use those names, such as
  `.padding(DesignTokens.margin)` and `spacing: DesignTokens.rhythm[2]`, instead of raw numbers.
  A custom frame's size sets the `#Preview`'s fixed layout.
- **Where each part lands:**
  - the data, the file and the token-reading rules: plan 2;
  - the export: plan 3;
  - the device picker, the "Custom size…" sheet, the Frames tab and token editing in the canvas
    settings: plan 4;
  - Siri's and voice's device choices including custom frames by name: plan 6.

## My calls (correct any of them)

1. **How the tree is held:** nested values with an index, and frames relative to the parent
   (see Approaches).
2. **How the branch gets there:** a staged cutover with a temporary projection, deleted before
   merge (see Approaches).
3. **Container kinds:** two, `.group` and `.card`. Rows, columns, grids and overlays are layouts
   of either, not kinds of their own. A plain free group of one dissolves, and every other
   container persists. This follows A2UI, where a Card holds a Column.
4. **Spacing:** no spacer node. Distribution (`justify`) and fill weights cover "actions at the
   bottom", following A2UI.
5. **Editing inside rows, columns and grids:** drag reorders and drag-out takes it out (Figma's
   convention). Dragging a member out of a free group's box still keeps it in the group (today's
   rule).
6. **The structure pass:** these are not settings this round.
   - The thresholds and the 0.8 and 0.5 confidence bars.
   - Automatic changes move nothing more than 8 pt.
   - Offers use a pill like "Did you mean".
   - No model is used for structure. The pill is the fallback for ambiguity, and a model can be
     measured later.
7. **Device changes** follow placement intent for free screens, and re-lay column screens,
   whatever made the change. Today only voice reflows.
8. **Hosted generation's format** is chosen by benchmark. A2UI is the default unless it is worse
   on validity or more than 25% slower to first content.
9. **Siri** still sees leaves only. Get Design Layout shows the tree.
10. **A2UI in Layer:**
    - Import comes through drop, paste, Files and Siri. Export is in the Share menu.
    - Unsupported parts become the nearest Layer kind plus a diagnostic, never silently dropped.
    - Layer's catalogue id is `urn:layer:a2ui:catalog:1`, and Layer's look travels in
      `@metadata.extensions.layer`.
11. **Code settings:** "Stack" is renamed "Structure", and "Exact positions" stays.
    - In Structure, free containers (a sketched screen's root included) are written by today's
      reading-order inference, read from the tree. Laid-out containers, cards and column roots
      follow §7's table.
    - Exact positions is absolute for everything.
    - Amended 2026-11-23 by plan 3's call 12.
12. **Limits:** depth 32, 5,000 nodes per design, and grid columns 1–12.
13. **Generation still always makes a new screen.** Siri's Build Screen of an existing screen
    reconciles rather than replacing it.
14. **No converter for older files** (B's consequence). Before installing this build on the iPad,
    open anything you want to keep in the current build and share it as an image or code.

From the builder check:

15. **Children have one order.** It is the stacking order everywhere, and the layout order in
    rows, columns and grids, where nothing overlaps.
    - Bring Forward, Send Backward and their kin are disabled for children of a row, column or
      grid. They still work in free and overlay containers.
    - In a row, column or grid, order changes come from drags, the Layers panel and voice's
      `reorder`.
    - When a free container becomes a row, column or grid (from the Format panel, Group as…,
      voice or the structure pass), its children are sorted into reading order first:
      - left to right for a row;
      - top to bottom for a column;
      - row by row for a grid.
16. **Sizing when a container is built from existing things.** This applies to the structure
    pass, Group as Row, Column or Grid, and voice's `groupElements`.
    - Every child becomes `fixed` at its current size, so nothing resizes. Only positions change,
      by the layout's spacing and alignment. The user can switch a child to Fit or Fill
      afterwards.
    - Generated and imported trees use the kinds' natural sizing instead: fit, and fill for kinds
      that run across.
    - The structure pass's 8 pt limit is the furthest any corner of any affected node moves.
      - It first tries the rhythm-rounded spacing.
      - If that moves something more than 8 pt, it uses the exact median gap.
      - If that is still more than 8 pt, it offers instead of applying.
17. **How hosted formats are measured.**
    - `ScreenBenchmarkHarness` becomes a small Swift package, so it can link the A2UI SDK and the
      app's parser sources.
    - The hosted runs use LM Studio on this Mac. This is local, needs no keys, and is how the
      voice benchmarks were run. Validity means the output parses and validates into a non-empty
      tree with no errors.
    - Until plan 6 measures, the shipped default for hosted models is A2UI, per the user's
      decision. If it misses the bar, the default flips to the outline, which is a one-line
      change, and the report says so.
18. **Saved frames are a snapshot, not trusted.**
    - Opening a design re-runs the engine on every screen before the store sees it. That is not
      an edit and makes no undo step.
    - The canvas draws each node exactly in its engine frame:
      - text in its frame, top-aligned and aligned by its own alignment, with no shrinking;
      - a card's look filling its frame.
    - A test checks that Core Text and SwiftUI agree on the height of a set of strings within
      1 pt in the simulator.
    - Goldens assert the engine's frames, which are deterministic numbers, not pixels.
19. **"Green" for the UI suite.** At the start of plan 2, the UI suite runs on main in the
    branch's simulator, and the tests that fail are recorded in the ledger. Later, green means no
    failure outside that set. The two failures known today are expected to be in it.
20. **Writing a frame through the projection (plans 2–4) to a child of a row, column or grid.**
    - A change of size sets `fixed` on the changed axis.
    - A change of position takes the child out of its container and onto its host's root at
      that place.

    These are the same rules a drag and Siri's Move Element follow later, and they are tested
    from plan 2.
21. **Test fixtures.** The version-4 fixture designs (`LayerTests/Fixtures/Designs/`) and
    `scripts/check-generated-swiftui.sh` are new, and plan 1 writes them. Today's fixtures are
    sketch JSON and stay as they are.

## Edge cases

- **A sketch drawn across a container's edge.** It lands in the container holding its centre.
  The card rule needs enclosed things at least 90% inside.
- **A sketch on a locked or hidden container.** It goes to the nearest unlocked, visible
  ancestor, or the root.
- **A sketch over a row.**
  - A new node goes into the row only if its centre is inside the row's box. Its place is decided
    by x, or by y for a column.
  - If that would make a stack child grow past its container's room, the engine reports overflow
    and nothing is corrected.
- **Ungrouping a turned container.** Its turn is baked into each child (position about the
  container's centre and angle summed), so nothing moves.
- **Undoing a structure step.** One undo returns the nodes to their parent and frames, and drops
  the container.
- **A generation streaming while the user drags a generated node.** The drag is its own step.
  The reconciler sees the node changed and leaves it alone.
- **An A2UI import with no `root`, or only unsupported components.** No screen is made, and the
  sheet says why.
- **An A2UI `updateComponents` with no `createSurface` before it.** It is accepted for import,
  with a diagnostic, using the catalogue named on the components or the Basic Catalog.
- **A cycle in imported A2UI.** The cycle is cut where it is found, with a diagnostic, and the
  rest is imported.
- **A free screen changing to a smaller device.**
  - Proportional nodes scale.
  - Leading and trailing nodes keep their insets, clamped inside the screen.
  - Fixed nodes stay put, and may overhang. The engine reports clipping, and nothing is
    corrected.
- **A node deleted while its "Make a row?" offer is showing.** The offer goes.
- **Old files in Files and Spotlight.** A tap shows the older-version message. Spotlight skips
  them.
- **Siri Move Element on a node inside a turned container.** Screen points are converted through
  the index, so it lands where asked.

## Verification

- **Unit tests:**
  - **The engine.** Nested rows, columns, cards, grids and overlays with measured text, two or
    more top-level groups, safe areas, `justify`, fill weights, min and max, overflow reports, no
    overlap among laid-out children, a free container's hugging, and an asymmetric sketch staying
    asymmetric.
  - **The structure pass.** Rows, columns, grids and cards. Near-misses, such as unrelated nearby
    things, that must not group. Movement capped at 8 pt, declines remembered, and one undo step.
  - **The store.** Every verb, the rules, and a three-way undo for every field (the field-list
    test).
  - **Saving.** Persistence round trips, version-3 refusal, unknown keys, and unread nodes.
  - **The reconciler.** Stable ids, user edits protected, and one undo step.
  - **A2UI:**
    - Fixtures: the official examples from the package's `catalogs/basic/v1/examples/`, copied in
      under Apache-2.0 with attribution.
    - Malformed and missing-version envelopes are rejected.
    - Cycle, unresolved, unreachable and template cases.
    - Actions are never run.
    - Layer → A2UI → Layer round trips.
  - **The outline parser.**
  - **Code goldens, and the compile check.**
  - **Today's suites, ported.** That covers groups, rotation, selection, the Format panel,
    Layers, Siri, voice and the reading log, with their behaviours kept unless this document
    changes them.
- **UI tests:**
  - Today's suite ported. It passes except the two known failures, if they still fail for their
    old reasons.
  - **The first milestone, end to end.** Sketch a card round two texts and a two-column grid, see
    them in the Layers panel, then export SwiftUI that contains `Grid` and the card's
    background.
- **Benchmarks:** the Performance table, before and after.
- **On the iPad:** a device checklist written with the plan. It covers Pencil latency while
  sketching rows, drag-reorder in a row, a turned container, device change, A2UI import from
  Files, and the old-file message.

## Left to the builder

- Type and file names beyond those named here, and how the views and the store split into files.
- The exact tables:
  - A2UI icon names to SF Symbols;
  - the catalogue's per-kind native sizes, beyond those named;
  - the Layer catalogue's JSON schemas.
- Tuning the structure thresholds within the stated limits, against new fixtures. Tuning is done
  by sketching rows, columns, grids and cards in the existing corpus style.
- How the insertion line looks, and how its hit areas work.
- Whether `ElementKind` is renamed. The 16 leaf kinds and the catalogue stay either way.
- An on-canvas list of issues for user-authored layouts is deferred. The validator exists, and
  showing its warnings is a later choice.

## How the work is split (for the plans)

All of it happens on `feature/semantic-tree`. Each plan ends with the app building, the unit
suite and the UI suite green (apart from the recorded baseline failures), and the compile check
passing.

On 2026-11-23 the user said: "the important part i want built is the screenblueprint removal for
a better, more enhanced structural design implementations". So structured generation comes
straight after the store cutover. That works because the projection already draws every leaf of a
laid-out tree at its resolved place, even before the canvas is rebuilt.

1. **The tree, the engine and the file.**
   - `LayerNode`, the layout engine, the index, the rules and the validator.
   - Version 4 encoding and decoding.
   - The outline parser.
   - The A2UI package with its importer and exporter.
   - The compile check.

   All of it is pure, and tested beside the old model.
2. **The store cutover.**
   - The tree becomes `content`, with the rules and undo on the tree.
   - The temporary projection keeps every caller working.
   - Saving and loading use version 4, and the baseline benchmark is recorded first.
3. **Structured generation, and `ScreenBlueprint` removed.**
   - The outline and A2UI generators, with the prompts rewritten and measured.
   - The reconciler, streaming into the store.
   - Siri's Build Screen and the library's templates moved to the outline.
   - A2UI import and export in the UI.
   - The SwiftUI export rewritten to follow the tree.
   - `ScreenBlueprint`, its grammar and `writeGenerated` deleted.
4. **The canvas and panels on the tree.**
   - Rendering, hit-testing and selection.
   - Move, resize and rotate, including layout-aware drags.
   - The Format panel's Layout and sizing, and the Layers panel.
   - Group as Row, Column, Grid or Card.
   - These callers leave the projection.
5. **The sketch path.**
   - Nodes with `SketchIntent`.
   - The structure pass and its pill.
   - Device changes by placement intent.
   - `ScreenTidy` deleted.
6. **Siri, voice, the last of the projection, and measuring.**
   - Siri and voice on the tree, with the new voice tools.
   - The projection and `DesignElement` deleted.
   - The benchmarks after the change, the report, and the iPad checklist.

Merging to main waits until all six are done and green. Pushing waits for the user's word.
