# Semantic tree, plan 1 of 6: the tree, the engine, the file, the outline and A2UI. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure foundations of the semantic tree, tested on their own beside today's model, which stays in use. They are:
- `LayerNode`;
- the layout engine;
- the index;
- the rules run after every change;
- the validator;
- the version-4 document coding;
- the outline parser;
- A2UI 1.0 import and export through the official SDK;
- a check that generated SwiftUI compiles.

**Architecture:** New value types and pure functions live in `Layer/Tree/` and `Layer/A2UI/`. Nothing in the running app uses them yet; plan 2 moves the store onto them. Three small changes touch existing code:
1. A rename that frees the `LayerNode` name.
2. A new `.card` kind with a catalogue entry.
3. Look-word parsing moved out of `ScreenBlueprint` so that the outline can share it. Behaviour is unchanged.

**Tech Stack:** Swift 6 (strict concurrency), Core Text, Swift Testing, XcodeGen, and the official A2UI Swift package (`A2UISwiftCore`, `BasicCatalog`).

**Spec:** `docs/superpowers/specs/2026-11-23-semantic-tree-design.md`. Read §1–§4, §6 (outline, A2UI import and catalogue), §9, §12, the Constraints, and My calls 3, 4, 10, 12, 15–21.

## Global Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, Swift Testing for unit tests (`@Suite`, `@Test`, `#expect`). Regenerate the project with `xcodegen generate` after adding files.
- **macOS builds:** everything in `Layer/Tree/` must build on macOS too, because the harnesses compile app sources there. So there is no UIKit and no SwiftUI in `Layer/Tree/`, and text is measured with Core Text. `Layer/A2UI/` may import A2UI modules but not UIKit or SwiftUI either.
- **Type names:**
  - Every new type that could clash with SwiftUI is nested in `LayerNode`: `LayerNode.Layout`, `.Stack`, `.Grid`, `.Alignment`, `.Padding`, `.Sizing`.
  - In files that import `OrderedJSON`, write the SDK's type as `OrderedJSON.JSONValue`. Plain `JSONValue` stays the app's own (`Layer/Document/JSONValue.swift`).
- **The A2UI package:**
  - URL `https://github.com/a2ui-project/a2ui`, pinned by **revision `07735d6a654ae3ba25951a8753ddd57b344b1169`** (tag `v0.11.0+swift`).
  - Products **`A2UISwiftCore` and `BasicCatalog` only**.
  - Never use `MessageProcessor`, `SurfaceGroupModel`, `A2UISwiftUI` or `BasicCatalogSwiftUI`.
- **Running A2UI content:** an A2UI `action`, `@call` or `callRendererFunction` is never evaluated or run. It is only reported.
- **Every `xcodebuild` command** (in this plan, in scripts and in docs) passes `-skipPackagePluginValidation`. If the first package build asks for macro validation, `-skipMacroValidation` joins it everywhere: record that in the ledger, and add it to the commands below.
- **Limits:**
  - tree depth 32;
  - 5,000 nodes per design;
  - grid columns 1–12;
  - A2UI graph depth 50.
- **Layer's numbers:**
  - rhythm 8, 12, 16, 24, 32;
  - margins 20 (phone), 32 (tablet), 48 (desktop);
  - desktop column at most 1080;
  - card: radius 16, padding 16, fill `RGBColor(hex: 0xF2F2F7)`.
- **A2UI identifiers:**
  - Layer's catalogue id is `urn:layer:a2ui:catalog:1`.
  - Layer's own look travels in a component's `@metadata.extensions.layer`.
- **The file:**
  - Version is 4, and `design.json` is encoded with `.sortedKeys`.
  - The older-version message is exactly: `This design was made by an earlier version of Layer and can't be opened by this one.`
  - The newer-version message stays exactly: `This design was saved by a newer version of Layer. Update Layer to open it.`
- **Nothing the app does changes in this plan.** The full unit suite stays green after every task.
- **The test command.** `<Suite>` is the `@Suite` struct's name:

  ```
  xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
    -destination "platform=iOS Simulator,name=Layer iPad Pro 11 (semantic-tree)" \
    -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Layer-semantic-tree" \
    -skipPackagePluginValidation -only-testing:LayerTests/<Suite>
  ```

  The full unit suite is the same command without `-only-testing`.

## Review Focus

1. **Non-finite or negative numbers reach the engine.** This happens through a decoded file, an import or arithmetic: a NaN or negative spacing, padding or size, or columns of 0 or 50. They must be read as 0 (and columns clamped to 1–12), and no frame the engine writes may be non-finite. Owned by Task 4 (`badNumbersNeverMakeABadFrame`) and Task 8 (`fixGenerated`).
2. **Very deep or very large trees, and cyclic A2UI graphs.** These are cut with a diagnostic. There must be no stack overflow and no hang. Owned by Task 8 (`aFortyDeepTreeIsFlattenedTo32`, `sixThousandNodesAreCutTo5000`) and Task 11 (`aCycleIsCutAndTheRestImported`, `aGraphDeeperThan50StopsThere`).
3. **Empty containers, and containers whose children are all hidden.** Hidden children take no space. An empty container fits its padding. Owned by Task 4 (`hiddenChildrenTakeNoSpace`, `anEmptyContainerFitsItsPadding`).
4. **Awkward text.** That means an empty string, one long word with no spaces, newlines, and emoji or CJK. Sizes must be finite, whole and never wider than the width given. Owned by Task 3 (`awkwardTextMeasuresSafely`).
5. **Malformed input.** For the outline: tabs, odd indents, `row:` with both inline items and indented children, and unknown kinds. For A2UI: duplicate ids, a missing root, and an `updateComponents` with no `createSurface`. These are parsed tolerantly with diagnostics, never crash, and never return a half-built root. Owned by Task 9 (`awkwardIndentationIsTolerated`) and Task 11 (`duplicateIdsAndAMissingRootAreReported`, `componentsWithoutCreateSurfaceStillImport`).

---

### Task 1: `LayerNode`, the card kind, and node coding

**Files:**
- Modify: `Layer/Model/Groups.swift` (rename the Layers panel's row struct `LayerNode` → `LayerListNode`), `Layer/Chrome/LayersPanel.swift` (its uses)
- Modify: `Layer/Model/Design.swift` (`ElementKind` gains `case card`), `Layer/Components/Catalogue.swift` (a `card` entry), every exhaustive `switch` on `ElementKind` that stops compiling (a card behaves exactly as `.group` does in old code: draws nothing, writes no code)
- Modify: `LayerTests/Goldens/ComponentKinds.txt` (regenerate with the card line)
- Create: `Layer/Tree/LayerNode.swift`, `Layer/Tree/LayerNode+Coding.swift`
- Test: `LayerTests/LayerNodeTests.swift`

**Interfaces:**
- Produces (in `LayerNode.swift`):
  ```swift
  struct LayerNode: Identifiable, Equatable, Sendable, Codable {
      var id = UUID()
      var kind: ElementKind
      var children: [LayerNode] = []          // back to front; the layout order in rows, columns, grids
      var unreadChildren: [UnreadChild] = []   // children this build couldn't read, kept at their index
      var layout: Layout? = nil                // containers only; nil reads as .free
      var padding = Padding()                  // containers only
      var width = Sizing(.fixed)
      var height = Sizing(.fixed)
      var frame = CGRect.zero                  // in the parent's space, upright
      var rotation: Double? = nil              // degrees clockwise about the frame's centre
      var scale: CGFloat? = nil                // top-level canvas nodes only
      var content = Content()
      var style = Style()
      var name: String? = nil
      var isLocked = false
      var isHidden = false
      var accessibility: Accessibility? = nil
      var sketch: SketchIntent? = nil
      var source: Source? = nil
      var interaction: JSONValue? = nil        // reserved; kept, never read
      var unknownKeys = UnknownKeys()
      init(kind: ElementKind)                  // other fields default
      var isContainer: Bool { get }            // kind == .group || kind == .card
      var resolvedLayout: Layout { get }       // layout ?? .free
  }
  extension LayerNode {
      enum Layout: Equatable, Sendable, Codable { case free, stack(Stack), grid(Grid), overlay(Alignment) }
      struct Stack: Equatable, Sendable, Codable { var axis: Axis; var spacing: CGFloat = 0
          var alignment: CrossAlignment = .start; var justify: Justify = .start }
      enum Axis: String, Sendable, Codable { case horizontal, vertical }
      enum CrossAlignment: String, Sendable, Codable { case start, center, end, fill }
      enum Justify: String, Sendable, Codable { case start, center, end, spaceBetween, spaceAround, spaceEvenly }
      struct Grid: Equatable, Sendable, Codable { var columns: Int; var columnSpacing: CGFloat = 0
          var rowSpacing: CGFloat = 0; var alignment = Alignment() }
      enum Edge3: String, Sendable, Codable { case start, center, end }
      struct Alignment: Equatable, Sendable, Codable { var horizontal = Edge3.center; var vertical = Edge3.center }
      struct Padding: Equatable, Sendable, Codable { var top: CGFloat = 0, leading: CGFloat = 0,
          bottom: CGFloat = 0, trailing: CGFloat = 0; init(all: CGFloat) }
      struct Sizing: Equatable, Sendable, Codable {
          enum Mode: Equatable, Sendable { case fit, fill(weight: CGFloat), fixed }
          var mode: Mode; var minimum: CGFloat? = nil; var maximum: CGFloat? = nil
          init(_ mode: Mode, minimum: CGFloat? = nil, maximum: CGFloat? = nil)
      }
      struct Content: Equatable, Sendable { var text = ""; var symbol: String? = nil; var shape: ShapeKind? = nil
          var imageID: UUID? = nil; var isOn = true; var value: Double? = nil; var buttonLook: ButtonLook? = nil
          var ink: Data? = nil }                      // ink is never coded (saved apart, as today)
      struct Style: Equatable, Sendable, Codable { var tint: RGBColor? = nil; var fontSize: CGFloat? = nil
          var fontWeight: FontWeightChoice? = nil; var textColor: RGBColor? = nil
          var textAlignment: TextAlignmentChoice? = nil; var cornerRadius: CGFloat? = nil
          var opacity: Double? = nil; var borderColor: RGBColor? = nil; var borderWidth: CGFloat? = nil
          var hasShadow = false }
      struct Accessibility: Equatable, Sendable, Codable { var label: String? = nil; var hint: String? = nil }
      enum DecidedBy: String, Sendable, Codable { case rules, handwriting, model, asked, structure }
      enum PlacementIntent: String, Sendable, Codable { case fixed, leading, trailing, centered, proportional }
      struct SketchIntent: Equatable, Sendable, Codable { var originalBounds: CGRect; var normalizedBounds: CGRect
          var confidence: Double; var decidedBy: DecidedBy; var placement: PlacementIntent
          var structureDeclined = false }
      enum Origin: String, Sendable, Codable { case user, sketch, generated, imported, template }
      struct Source: Equatable, Sendable, Codable { var origin: Origin; var key: String? = nil }
      struct UnreadChild: Equatable, Sendable { var index: Int; var raw: JSONValue }
  }
  ```
- Produces: `ElementKind.card` with `ElementKind.card.spec` (`Catalogue.card`).

- [ ] **Step 1: Make the branch's simulator, and check the starting point**

  Run `xcrun simctl clone "iPad Pro 11-inch (M5)" "Layer iPad Pro 11 (semantic-tree)"`, then `xcodegen generate` and the full unit suite. Expected: TEST SUCCEEDED. Record the simulator's UDID in the ledger: it gets deleted after the work, along with the DerivedData path in the test command.

- [ ] **Step 2: Free the name.** Rename the Layers panel's row type `LayerNode` (Groups.swift:704) to `LayerListNode`, along with its uses in `Groups.swift` and `LayersPanel.swift`. Run `LayersPanelTests` and `GroupTests`. Expected: PASS.

- [ ] **Step 3: Write the failing tests** in `LayerTests/LayerNodeTests.swift`, `@Suite struct LayerNodeTests`:
  - `aNodeRoundTripsEveryField`:
    - Build a card holding a stack (vertical, spacing 12, alignment `.fill`, justify `.spaceBetween`), padding 16, and two children.
    - The first child is a text with every `Style` field set, plus `sketch`, `source`, `accessibility`, `interaction: .object(["future": .bool(true)])`, rotation 30, width `.fill(weight: 2)` with min 40 and max 300, and height `.fit`.
    - The second child is a grid layout group with columns 3 and spacings, and alignment (end, start).
    - `#expect(try JSONDecoder().decode(LayerNode.self, from: JSONEncoder().encode(node)) == node)`, where ink is nil.
  - `inkIsNeverWritten`: a drawing node with `content.ink = Data([1,2,3])` encodes to JSON without the bytes, and decodes with `ink == nil`.
  - `unknownKeysOnANodeSurviveARoundTrip`: decode `{"id":…,"kind":"text","hologram":{"x":1}}`; the re-encoded JSON object contains `"hologram":{"x":1}`.
  - `aChildOfAnUnknownKindIsKeptAtItsPlace`:
    - Children JSON: `[text, {"id":…,"kind":"hologram"}, button]`.
    - It decodes to `children.map(\.kind) == [.text, .button]` and `unreadChildren == [UnreadChild(index: 1, raw: …)]`.
    - Encoding writes three children with the raw one second.
  - `missingFieldsTakeTheirDefaults`: `{"id":…,"kind":"text"}` decodes with `width == Sizing(.fixed)`, `layout == nil`, `frame == .zero`, `children == []`, `isLocked == false`.
  - `onlyGroupsAndCardsAreContainers`: `ElementKind.allCases.filter { LayerNode(kind: $0).isContainer } == [.group, .card]`.
  - `theCardHasAQuietCatalogueEntry`:
    - `ElementKind.card.spec.name == "Card"`, and `writtenNames == []`, like the group.
    - `isAskedForOnScreens == false`, `cornerRadius` is `.points(16)`, and `tint == RGBColor(hex: 0xF2F2F7)`.
    - `UIImage(systemName: ElementKind.card.symbol) != nil`.

- [ ] **Step 4: Run them.** Run `LayerNodeTests`. Expected: FAIL (`LayerNode` has no `kind` initialiser, and there is no `.card`).

- [ ] **Step 5: Add `.card`.** Add `case card` to `ElementKind` and `Catalogue.card`. Mirror `Catalogue.group` (no written names, not asked for on screens, `size: .fixed(.zero)`, minimum 8×8) except:
  - `name: "Card"`;
  - an SF Symbol of your choice that exists;
  - `promptName: "card"`;
  - `tint: RGBColor(hex: 0xF2F2F7)`;
  - `cornerRadius: .points(16)`;
  - `hasEffects: true`;
  - `traits: [.fill, .cornerRadius, .border]`.

  Make each old exhaustive `switch` treat `.card` as `.group`. A card must not appear in any prompt or kind list where `.group` doesn't, so `SketchHintTests` and `ScreenGenerationTests` stay green untouched. Regenerate `ComponentKinds.txt` the way its test explains.

- [ ] **Step 6: Implement `LayerNode.swift` and `LayerNode+Coding.swift`.**
  - Coding follows `DesignElement`'s pattern:
    - `id` and `kind` are required; everything else uses `decodeIfPresent` with the defaults above.
    - Unknown keys go through `UnknownKeys(from:besides:)` and `WithUnknownKeys`.
    - Children are decoded one at a time; one that fails becomes an `UnreadChild` at its index, as `DesignElement.readList` does.
  - The `Layout` JSON is `{"type":"free"}`, `{"type":"stack","axis":…,"spacing":…,"alignment":…,"justify":…}`, `{"type":"grid","columns":…,"columnSpacing":…,"rowSpacing":…,"horizontal":…,"vertical":…}` or `{"type":"overlay","horizontal":…,"vertical":…}`.
  - The `Sizing` JSON is `{"mode":"fit"|"fill"|"fixed","weight":…,"min":…,"max":…}`.
  - Optionals are omitted when nil.

- [ ] **Step 7: Run them.** Run `LayerNodeTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 8: Commit.** `git add -A && git commit -m "LayerNode: the semantic tree's node, the card kind, and node coding with unknown keys and unread children kept"`

---

### Task 2: The version-4 document

**Files:**
- Create: `Layer/Tree/TreeContent.swift`
- Create: `LayerTests/Fixtures/Designs/design-profile.json`, `LayerTests/Fixtures/Designs/design-sketch.json` (version-4 manifests, written by hand, described in Step 1)
- Test: `LayerTests/TreeContentTests.swift`

**Interfaces:**
- Consumes: `LayerNode` (Task 1), `CanvasSettings`, `DeviceFrame` (Design.swift)
- Produces:
  ```swift
  struct TreeScreen: Identifiable, Equatable, Sendable, Codable {
      var id = UUID(); var name: String; var origin: CGPoint; var scale: CGFloat
      var deviceID: String? = nil; var isLocked: Bool? = nil
      var root: LayerNode                      // kind .group, frame = device bounds, sizing fixed
      var unknownKeys = UnknownKeys()
      var device: DeviceFrame { get }          // DeviceFrame.named(deviceID)
      init(name: String, origin: CGPoint, scale: CGFloat, deviceID: String?, root: LayerNode? = nil)
  }
  struct TreeContent: Equatable, Sendable, Codable {
      var screens: [TreeScreen] = []; var canvas: [LayerNode] = []
      var title: String? = nil; var settings = CanvasSettings(); var unknownKeys = UnknownKeys()
  }
  enum TreeManifest {
      static let version = 4
      enum ReadError: LocalizedError, Equatable { case olderVersion(Int), newerVersion(Int), unreadable }
      static func encode(_ content: TreeContent, fileName: String?) throws -> Data
      static func decode(_ data: Data) throws -> (content: TreeContent, fileName: String?)
  }
  ```

- [ ] **Step 1: Write the fixtures.**
  - `design-profile.json` is a version-4 manifest with one iPhone screen named "Profile". Its root is a column (spacing 24) holding:
    - a title "Profile";
    - a row of an avatar and the text "Alex Tan";
    - a card holding a column of a text "About me" and a body "Designing better experiences.";
    - a grid of 2 columns with four texts;
    - a filled button "Edit profile".

    Every node has an id, a kind, and sizing per the natural defaults (fill for button, body and card; fit otherwise).
  - `design-sketch.json` has one iPhone screen with a **free** root and four fixed nodes at asymmetric places:
    - a title at (20, 80, 228, 40);
    - an image at (200, 140, 160, 120);
    - a button at (20, 700, 160, 50);
    - a toggle at (310, 300, 51, 31).

    The canvas holds one sticky note with `scale` 0.66.

- [ ] **Step 2: Write the failing tests** in `TreeContentTests`:
  - `aDesignRoundTrips`: decoding the encoding of the profile fixture's content equals it, and so does `fileName`.
  - `encodingIsTheSameEveryTime`: two encodings of the same content are byte-equal, and the JSON's keys are sorted.
  - `anOlderDesignIsRefusedWithItsMessage`:
    - `{"version":3,"content":{}}` throws `.olderVersion(3)`.
    - Its `errorDescription` is exactly the Global Constraints' older-version message.
  - `aNewerDesignIsRefused`: version 5 throws `.newerVersion(5)` with the newer-version message.
  - `unknownKeysAreKeptAtEveryLevel`: unknown keys on the manifest, the content, a screen and a node all survive a round trip.
  - `aScreensRootIsKeptToItsDevice`:
    - Decode a screen whose root has kind `.text`, frame (5, 5, 10, 10) and rotation 20.
    - It comes back as kind `.group`, frame `(0, 0, 393, 852)` for the iPhone, both sizings `.fixed`, and rotation nil.
  - `theFixturesRead`: both fixtures decode, and each screen's root counts 15 and 5 nodes, the root included (a recursive walk).

- [ ] **Step 3: Run them.** Run `TreeContentTests`. Expected: FAIL (the types don't exist).

- [ ] **Step 4: Implement `TreeContent.swift`.**
  - The manifest is `{"version":4,"fileName":…?,"content":{"screens":[…],"canvas":[…],"title":…?,"settings":{…}}}`.
  - Unknown keys are kept on the manifest, content and screen.
  - Version below 4 throws `olderVersion`, and above 4 throws `newerVersion`. A non-object or a missing `content` throws `unreadable`.
  - Decoding forces each screen root to the rules in the test.
  - The messages are the exact strings in the Global Constraints.

- [ ] **Step 5: Run them.** Run `TreeContentTests`. Expected: PASS.

- [ ] **Step 6: Commit.** `git commit -am "TreeContent: version-4 design.json with screens holding root nodes, the canvas's nodes, and older and newer files refused"` (add the new files first).

---

### Task 3: Measuring text, and natural sizes

**Files:**
- Create: `Layer/Tree/TextMeasure.swift`, `Layer/Tree/NaturalSize.swift`
- Test: `LayerTests/TextMeasureTests.swift`

**Interfaces:**
- Consumes: `LayerNode` (Task 1), `ElementKind.spec` (Catalogue)
- Produces:
  ```swift
  final class TextMeasure: Sendable {
      static let shared: TextMeasure
      /// Whole points (rounded up). `width` nil = one line's natural width. Empty text = zero width, one line high.
      func size(of text: String, fontSize: CGFloat, weight: FontWeightChoice, width: CGFloat?) -> CGSize
      #if DEBUG
      var misses: Int { get }      // measurements not found in the cache
      #endif
  }
  enum NaturalSize {
      static func fontSize(of node: LayerNode) -> CGFloat      // style ?? the kind's: title 28, body 15, text 17, button 17, textField 16
      static func fontWeight(of node: LayerNode) -> FontWeightChoice
      /// A leaf's natural size for an offered width (nil = ideal). Not for containers.
      static func of(_ node: LayerNode, width: CGFloat?, measure: TextMeasure) -> CGSize
      /// The sizing a generated or imported node of this kind starts with.
      static func defaultSizing(for kind: ElementKind) -> (width: LayerNode.Sizing, height: LayerNode.Sizing)
  }
  ```
- **Natural sizes** (`of`):

  | Kind | Width × height |
  |---|---|
  | title, body, text, stickyNote's words | the measured text at its font, wrapping at `width` |
  | button | label measured with semibold 17, plus 40, at least 44 wide × 50 |
  | textField | `width` ?? 280 × 48 |
  | divider | `width` ?? 1 × 1 |
  | progress | `width` ?? 333 × 6 |
  | image | `width` ?? 333 × 200 |
  | symbol | 44 × 44 |
  | toggle | 51 × 31 |
  | checkbox, radio | 24 × 24 |
  | avatar | 48 × 48 |
  | shape | 100 × 100 |
  | stickyNote | 150 × 150 |
  | drawing | its frame's size |

  `defaultSizing`: kinds with `spec.fillsWrittenWidth` get width `.fill(weight: 1)`, and every other kind `.fit`. Height is `.fit` for all. A card gets width `.fill(weight: 1)` and height `.fit`.

- [ ] **Step 1: Write the failing tests** in `TextMeasureTests`:
  - `emptyTextIsOneLineHigh`: width 0, and height equals the measured height of "A".
  - `longTextWrapsWithinTheWidth`: 200 words at 15 pt in width 300 give width ≤ 300 and height > 5 × the one-line height.
  - `awkwardTextMeasuresSafely`:
    - The inputs are a 400-character word with no spaces in width 120, `"a\nb\nc"`, `"🙂👋🏽"`, and `"日本語のテキスト"`.
    - Every size is finite and whole (`== .rounded(.up)`).
    - With a width, every result's width is ≤ that width.
    - The newline text is at least 3 lines high.
  - `measuringAgainUsesTheCache`: measuring the same string, font and width twice raises `misses` by exactly 1.
  - `coreTextAgreesWithSwiftUI`:
    - Ten strings of varied lengths at 15 regular and 28 bold, in width 300.
    - `TextMeasure`'s height is within 1 pt of the result of `UIHostingController(rootView: Text(s).font(.system(size:weight:))).sizeThatFits(in: CGSize(width: 300, height: .greatestFiniteMagnitude))`.
    - This test may import SwiftUI and UIKit; the source files may not.
  - `naturalSizesFollowTheTable`: every fixed row of the table, and a button's width equals its label's measured width plus 40.
  - `generatedNodesStartWithTheKindsSizing`:
    - `defaultSizing(for: .body).width.mode == .fill(weight: 1)`;
    - `.title` is `.fit`;
    - `.button` is `.fill`;
    - `.card` is `.fill`.

- [ ] **Step 2: Run them.** Run `TextMeasureTests`. Expected: FAIL.

- [ ] **Step 3: Implement `TextMeasure`.**
  - Use `CTFramesetterSuggestFrameSizeWithConstraints` with a system font of the size and weight.
  - Map `FontWeightChoice` to `kCTFontWeightTrait`: regular 0, medium 0.23, semibold 0.3, bold 0.4.
  - Measure at the default Dynamic Type size.
  - Cache by `(text, fontSize, weight, width)` under an `OSAllocatedUnfairLock`, keeping the newest 2,000 entries.
  - Round up to whole points.
  - Treat a non-finite, zero or negative `width` as nil.

- [ ] **Step 4: Implement `NaturalSize`** per the table.

- [ ] **Step 5: Run them.** Run `TextMeasureTests`. Expected: PASS.

- [ ] **Step 6: Commit.** `git commit -am "TextMeasure and NaturalSize: Core Text measurement with a cache, and each kind's natural size and starting sizing"`

---

### Task 4: The layout engine: rows, columns, grids, overlays

**Files:**
- Create: `Layer/Tree/LayoutEngine.swift`
- Test: `LayerTests/LayoutEngineTests.swift`

**Interfaces:**
- Consumes: `LayerNode` (Task 1), `TextMeasure`, `NaturalSize` (Task 3)
- Produces:
  ```swift
  struct ProposedSize: Equatable, Sendable { var width: CGFloat?; var height: CGFloat? }
  struct LayoutDiagnostic: Equatable, Sendable {
      enum Kind: Equatable, Sendable { case overflow, textTooWide, clipped, smallControl }
      var node: UUID; var kind: Kind
  }
  enum LayoutEngine {
      /// The size `node` takes for `proposal`: fixed sizes, natural sizes, or (containers) content plus padding.
      static func size(of node: LayerNode, proposal: ProposedSize, measure: TextMeasure) -> CGSize
      /// Places `node`'s children for `node.frame.size`, recursively, writing their frames.
      static func layOut(_ node: inout LayerNode, previous: LayerNode?, measure: TextMeasure,
                         diagnostics: inout [LayoutDiagnostic])
  }
  ```
- **The rules** (spec §4). Main axis means the stack's axis.
  1. Padding insets the content box.
  2. Hidden children take no space, and their frames are left as they are.
  3. On the main axis:
     - `.fixed` children take their frame size;
     - `.fit` children take `size(of:)` at their offered size, clamped to their minimum and maximum;
     - `.fill(weight)` children share what is left after spacing, in proportion to weight, each clamped. A share clamped by a maximum stays unused.
  4. On the cross axis:
     - `.fill` sizing always stretches to the content box;
     - stack alignment `.fill` stretches every child that isn't `.fixed` on that axis;
     - otherwise the child's fixed or natural size, placed by `.start`, `.center` or `.end`.
  5. `justify` spreads leftover main-axis space only when no visible child fills:
     - `spaceBetween` puts it in the gaps;
     - `spaceAround` gives half-gaps at the ends;
     - `spaceEvenly` gives equal gaps, ends included.
  6. **Grids:**
     - column width = (inner width − (columns − 1) × columnSpacing) / columns;
     - children fill row by row;
     - a filling child takes its cell's width, and other children take their fixed or natural size at the column width;
     - each row is as tall as its tallest cell;
     - children sit in their cells per the grid's alignment.
  7. **Overlays:** each child is sized as in a grid's cell, at the content box, and placed by the container's alignment. A fitting overlay is its largest child plus padding.
  8. **Fitting containers:**
     - a column fits its children's main-axis sum plus spacing, and its widest child;
     - a row is the transpose;
     - a grid fits its rows.
  9. **Overflow:** if content needs more main-axis room than a container has, the container gets an `.overflow` diagnostic. Nothing shrinks below its fixed or natural size.
  10. **Bad numbers:** non-finite or negative spacing, padding, sizes, minimums and maximums are read as 0, or as nil for min and max. Columns are clamped to 1–12.
  11. Frames are whole points except for drawings.
  12. `.free` is Task 5's. For now, treat it as "children keep their frames".

- [ ] **Step 1: Write the failing tests** in `LayoutEngineTests`. Leaves are shapes with `.fixed` sizing unless the test says otherwise.
  - `aColumnStacksChildrenWithSpacingAndPadding`:
    - A column (spacing 12, alignment `.start`), padding 16, frame size 393 × 400.
    - Children 100×40 and 200×20 get frames (16,16,100,40) and (16,68,200,20).
    - `size(of:proposal: (393, nil)).height == 104`.
  - `fillingChildrenShareTheRestByWeight`: a row 300 wide, spacing 0, with fixed 100, fill(1) and fill(3), gives widths 100, 50 and 150 at x 0, 100 and 150.
  - `minimumAndMaximumClampAFillingChild`: as above, but the fill(3) child has maximum 120: widths 100, 50 and 120.
  - `crossAxisAlignmentPlacesAndStretches`: a row 300 × 100 with a fixed 50×40 child:
    - `.start` gives y 0, `.center` 30 and `.end` 60;
    - `.fill` with the child's height `.fit` gives height 100;
    - `.fill` with the child's height `.fixed` keeps 40 at y 0.
  - `justifySpreadsTheLeftover`: a row 300 with three fixed 50-wide children:
    - `spaceBetween` gives x 0, 125, 250;
    - `spaceAround` gives 25, 125, 225;
    - `spaceEvenly` gives 37.5 rounded, which is 38, 125, 213, under the whole-point rule;
    - `center` gives 75, 125, 175.
  - `justifyIsIgnoredWhenAChildFills`.
  - `aGridFillsRowByRowWithEqualColumns`: grid columns 2, columnSpacing 10, rowSpacing 8, frame 210 wide, four 100×30 children, alignment (start, start). Cells are (0,0), (110,0), (0,38) and (110,38).
  - `aGridRowIsAsTallAsItsTallestCell`: in a row of 30- and 50-high children, the next row starts at 50 + rowSpacing.
  - `anOverlayAlignsEveryChild`: a 200×200 overlay aligned (end, end) puts a 50×50 child at (150,150). A fitting overlay with children 80×20 and 40×60 is 80×60.
  - `cardsAndColumnsNest`:
    - A column root 393 wide (padding 20) holds a card (padding 16, column spacing 8, width `.fill`) with two 100×20 children.
    - The card's frame is (20, 20, 353, 16+20+8+20+16 = 80).
    - Its children are at (16,16) and (16,44) in the card's space.
  - `laidOutChildrenNeverOverlap`:
    - A column root holds two top-level groups (a row of three and a grid of four, each fitting).
    - No two siblings' frames intersect, at any depth.
  - `textInAColumnWrapsToTheColumnWidth`:
    - A body with `.fill` width in a column 300 wide.
    - Its frame width is 300, and its height equals `TextMeasure.shared.size(of:fontSize: 15, weight: .regular, width: 300).height`.
  - `overflowIsReportedNotCorrected`: a fixed 100-wide row with two fixed 80-wide children reports `.overflow` for the row, and both children keep width 80.
  - `hiddenChildrenTakeNoSpace`: in a column with spacing 10 holding A, hidden B and C, C is placed right after A plus 10.
  - `anEmptyContainerFitsItsPadding`: a fitting column with padding 16 and no children is 32 × 32.
  - `badNumbersNeverMakeABadFrame`:
    - Spacing `.nan`, padding −5, a child minimum `.infinity`, and grid columns 0 and 50.
    - Every frame written is finite.
    - Spacing and padding act as 0.
    - Columns act as 1 and 12.

- [ ] **Step 2: Run them.** Run `LayoutEngineTests`. Expected: FAIL.

- [ ] **Step 3: Implement `LayoutEngine.size(of:proposal:measure:)` and `layOut(_:previous:measure:diagnostics:)`** per the rules. `previous` is unused until Task 5.

- [ ] **Step 4: Run them.** Run `LayoutEngineTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -am "LayoutEngine: rows, columns, grids and overlays with fit, fill and fixed sizing, padding, alignment, distribution and overflow reports"`

---

### Task 5: Free containers that hug their content, and re-laying only what changed

**Files:**
- Modify: `Layer/Tree/LayoutEngine.swift`, `Layer/Tree/LayerNode.swift` (a transform helper)
- Test: `LayerTests/LayoutEngineFreeTests.swift`

**Interfaces:**
- Consumes: Task 4
- Produces:
  ```swift
  extension LayerNode {
      /// This node's own space to its parent's: translate to frame.origin, then turn about the frame's centre.
      var transformToParent: CGAffineTransform { get }
  }
  #if DEBUG
  extension LayoutEngine { static var containersLaidOut: Int { get } }   // counted under a lock
  #endif
  ```
- **The rules:**
  - A `.free` container leaves its children's frames as they are.
  - When its width or height sizing is `.fit` (`.group`s made by Group are fit on both axes), it hugs its children:
    - Its size on that axis becomes the box round its visible children's turned shapes (`TurnedRect(rect: frame, degrees: rotation ?? 0).bounds`).
    - The children are shifted so that the box starts at 0.
    - The container's own `frame.origin` moves so that **every child stays where it was in the parent's space**. This holds for a turned container too.
  - If a container is equal to `previous`'s same-id child, and is given the same size as its frame there, it is not re-laid out, and its subtree is left as it is. `containersLaidOut` counts the containers actually laid out.

- [ ] **Step 1: Write the failing tests** in `LayoutEngineFreeTests`:
  - `aFreeContainerKeepsItsChildrensFrames`: a free root at 393×852 with asymmetric children (the `design-sketch` fixture's frames) is unchanged after `layOut`.
  - `aFittingFreeGroupHugsItsChildrenAndNothingMoves`:
    - A free fit group at (50,50,999,999) with children (10,10,20,20) and (40,30,10,10).
    - The group becomes (60,60,40,30), and its children (0,0,20,20) and (30,20,10,10).
    - Each child's frame mapped through `transformToParent` is unchanged.
  - `aTurnedFittingFreeGroupKeepsItsChildrenWhereTheyWere`: as above with the group's rotation 30. Each child's centre in the parent's space is within 0.001 of where it was before.
  - `turnedChildrenAreBoxedByTheirTurnedShapes`: a 100×20 child turned 90 makes a fitting group 20×100 (allowing for the whole-point rule).
  - `anUnchangedSubtreeIsNotLaidOutAgain`:
    - Lay out a root holding three containers, then copy it as `previous`.
    - Change one leaf's text in container B and lay out again with `previous`.
    - `containersLaidOut` rose by exactly 2: the root and B.
  - `aRowInAFreeScreenKeepsItsPlace`: a fitting row at (40, 200) in a free root keeps origin (40, 200) when a child's width grows.

- [ ] **Step 2: Run them.** Run `LayoutEngineFreeTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `transformToParent`, hugging with the compensating origin move, and the reuse rule.

- [ ] **Step 4: Run them.** Run `LayoutEngineFreeTests` and `LayoutEngineTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -am "LayoutEngine: free containers that hug their content without moving it, and unchanged subtrees left alone"`

---

### Task 6: The index

**Files:**
- Create: `Layer/Tree/TreeIndex.swift`
- Test: `LayerTests/TreeIndexTests.swift`

**Interfaces:**
- Consumes: `TreeContent`, `TreeScreen` (Task 2), `transformToParent` (Task 5), `TurnedRect`, `Placement` (existing)
- Produces:
  ```swift
  struct TreeIndex: Sendable {
      enum Host: Hashable, Sendable { case screen(TreeScreen.ID), canvas }
      struct Entry: Sendable {
          var host: Host; var parent: UUID?; var siblingIndex: Int; var depth: Int; var path: [Int]
          var toHost: CGAffineTransform          // this node's space to its host's (screen points, or canvas points)
          var hostShape: TurnedRect              // its frame in the host's space, with its summed angle
          var isLockedWithAncestors: Bool; var isHiddenWithAncestors: Bool
      }
      init(_ content: TreeContent)
      subscript(_ id: UUID) -> Entry? { get }
      var count: Int { get }
      func ancestors(of id: UUID) -> [UUID]                         // nearest first
      func node(_ id: UUID, in content: TreeContent) -> LayerNode?  // by path
      func canvasShape(of id: UUID, in content: TreeContent) -> TurnedRect?  // screen nodes through the screen's Placement
  }
  ```
- **Notes:**
  - A screen's root is in the index, with host `.screen(id)`, `parent` nil and depth 0.
  - On the canvas, a top-level node's `toHost` is `scale(s)` after `transformToParent`, where `s = scale ?? 1`. Its descendants compose under it.

- [ ] **Step 1: Write the failing tests** in `TreeIndexTests`:
  - `everyNodeHasAnEntry`: for the profile fixture, `count` equals the recursive node count, and each entry's `path` leads back to its node.
  - `aChildOfATurnedContainerHasItsTurnedPose`:
    - A free group at (100,100,200,100), turned 90, holds a 20×20 child at (0,0).
    - The child's `hostShape.degrees == 90`.
    - Its centre is the group's centre plus the child's offset turned by 90°: (200,150) + rotate((−90,−40), 90°) = (240, 60).
  - `lockAndHideComeFromAncestors`: a locked card's grandchild is `isLockedWithAncestors`, and a hidden row's child is `isHiddenWithAncestors`.
  - `canvasNodesUseTheirScale`: a canvas sticky note with frame (100,100,150,150) and scale 0.5 has `hostShape.rect == (50,50,75,75)`.
  - `aScreenNodesCanvasShapeGoesThroughTheScreen`: on a screen at origin (1000, 0) and scale 0.5, a node at (20, 40, 100, 50) has a canvas shape rect of (1010, 20, 50, 25).
  - `ancestorsAreNearestFirst`.
  - `aLargeDesignIsIndexedQuickly`: 5,000 nodes over 10 screens are indexed in under 50 ms, as the median of 5 runs.

- [ ] **Step 2: Run them.** Run `TreeIndexTests`. Expected: FAIL.

- [ ] **Step 3: Implement `TreeIndex`.** It is built in one walk over every node, so the cost is O(N).

- [ ] **Step 4: Run them.** Run `TreeIndexTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -am "TreeIndex: each node's host, parent, path, transform, shape and inherited lock and hide, built in one walk"`

---

### Task 7: The rules after every change

**Files:**
- Create: `Layer/Tree/TreeRules.swift`
- Test: `LayerTests/TreeRulesTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 5, 6
- Produces:
  ```swift
  enum TreeRules {
      static let maximumDepth = 32
      static let maximumNodes = 5_000
      /// Structure first, then layout of what changed since `previous` (everything when nil). Idempotent.
      @discardableResult
      static func apply(to content: inout TreeContent, after previous: TreeContent?,
                        measure: TextMeasure = .shared) -> [LayoutDiagnostic]
      /// Desktop column at most 1080; the margin for a device's family: 20, 32, 48.
      static func margin(for device: DeviceFrame) -> CGFloat
  }
  ```
- **Structure, in order:**
  1. **Screen roots:** each is kept as kind `.group`, at frame `(0,0)+device.size`, with fixed sizing and no rotation.
  2. **Drawings:** a drawing anywhere but the canvas's top level moves there at the same canvas position. A screen node goes to canvas points with the screen's scale.
  3. **Sticky notes:** a sticky note on a screen moves to the canvas's top level the same way.
  4. **Empty groups:** an empty `.group` is removed. That excludes screen roots and cards.
  5. **Free groups of one:** a free `.group` holding one child dissolves.
     - The child takes the group's slot, with its frame and angle converted to the parent's space so that it doesn't move.
     - It also takes the group's `isLocked` and `isHidden`, combined by OR.
     - Groups with any other layout, and cards, stay with any number of children.
- **Layout:**
  - Each screen whose root differs from `previous`'s same-id screen, or whose device changed, is laid out at its device size, with `previous`'s root passed in.
  - A **column (stack) root** has padding equal to the device's safe top and bottom plus the margin on every side. A desktop root limits its content to 1080 wide, centred.
  - Each top-level canvas container is laid out at its own size.

- [ ] **Step 1: Write the failing tests** in `TreeRulesTests`:
  - `aDrawingInsideAContainerGoesToTheCanvasWhereItWas`.
  - `aStickyNoteOnAScreenGoesToTheCanvas`.
  - `anEmptyGroupGoesButAnEmptyCardStays`.
  - `aFreeGroupOfOneDissolvesWithoutMovingAndHandsDownLockAndHide`: the group is turned 45 and locked. The child's host centre is unchanged within 0.001, its angle is the sum, and it is locked.
  - `aRowOfOneStays`.
  - `aScreensRootIsKeptToItsDevice`.
  - `aColumnRootIsInsetBySafeAreasAndMargin`: on the iPhone, the first child's frame minY equals `safeTop + 20` and its minX is 20. On a desktop device, the content is ≤ 1080 wide and centred.
  - `onlyScreensThatChangedAreLaidOut`: two screens; change one leaf on screen A. `containersLaidOut` grows only by A's changed path.
  - `applyingTwiceChangesNothing`.
  - `oneEditOnAHundredNodeScreenIsQuick`:
    - A column screen of 100 nodes: 25 rows of a text, a body, a toggle and a divider.
    - Change one text 50 times, each time `apply(to:after:)` with the previous content.
    - The p95 time is under 16 ms. Print p50 and p95 for the ledger.

- [ ] **Step 2: Run them.** Run `TreeRulesTests`. Expected: FAIL.

- [ ] **Step 3: Implement `TreeRules`.**

- [ ] **Step 4: Run them.** Run `TreeRulesTests`. Expected: PASS. If the timing fails, profile and fix the engine's reuse before going on: the budget is the spec's.

- [ ] **Step 5: Commit.** `git commit -am "TreeRules: the structure rules and the layout of changed screens after every change, within the 16 ms budget"`

---

### Task 8: The validator

**Files:**
- Create: `Layer/Tree/TreeValidator.swift`
- Test: `LayerTests/TreeValidatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4
- Produces:
  ```swift
  enum TreeValidator {
      struct Issue: Equatable, Sendable {
          enum Kind: Equatable, Sendable { case notAllowedHere, tooDeep, tooMany, badGeometry, clipped, smallText, smallControl }
          var node: UUID?; var kind: Kind
      }
      /// Reports; never changes anything. `device` nil = not on a screen.
      static func check(_ root: LayerNode, on device: DeviceFrame?) -> [Issue]
      /// For generated and imported trees only: fixes what can be fixed and reports it.
      static func fixGenerated(_ root: inout LayerNode) -> [Issue]
  }
  ```
- **What `check` reports:**
  - a child under a leaf, or a drawing anywhere: `notAllowedHere`;
  - depth beyond 32: `tooDeep`;
  - more than 5,000 nodes: `tooMany`;
  - a non-finite or negative frame size, spacing or padding: `badGeometry`;
  - a node outside the device bounds: `clipped`;
  - text kinds under 11 pt: `smallText`;
  - a button or text field under 44 pt high: `smallControl`.
- **What `fixGenerated` does:**
  - reads bad numbers as 0;
  - clamps grid columns to 1–12;
  - raises buttons and text fields to 44 high;
  - raises text to 11 pt;
  - moves nodes deeper than 32 up into their depth-32 ancestor, in order;
  - drops nodes past the 5,000th in reading order;
  - drops children of leaves.

  Each fix reports its issue. It works without recursing deeper than 33 levels, so it is safe on any input.

- [ ] **Step 1: Write the failing tests** in `TreeValidatorTests`:
  - One test per issue kind for `check`.
  - `checkNeverChangesTheTree`: `check` takes the tree by value; assert the tree is equal after the call.
  - `fixGeneratedFixesAndReports`: one tree holding each fixable problem. After the fix, `check` reports only `clipped`, if anything.
  - `aFortyDeepTreeIsFlattenedTo32`: the depth becomes 32, all 40 leaves survive, and a `tooDeep` is reported.
  - `sixThousandNodesAreCutTo5000`: the first 5,000 in reading order remain, and `tooMany` is reported.

- [ ] **Step 2: Run them.** Run `TreeValidatorTests`. Expected: FAIL.

- [ ] **Step 3: Implement `TreeValidator`.**

- [ ] **Step 4: Run them.** Run `TreeValidatorTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -am "TreeValidator: checks for every tree, and fixes for generated and imported ones"`

---

### Task 9: Look words, and the outline

**Files:**
- Create: `Layer/Tree/LookWords.swift`, `Layer/Tree/Outline.swift`
- Modify: `Layer/Model/ScreenBlueprint.swift`: use `LookWords` for `Item`'s look parsing, `ColourWords` and `kind(named:)`, with behaviour unchanged.
- Test: `LayerTests/OutlineTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 3
- Produces:
  ```swift
  struct Look: Equatable, Sendable {      // what look words in brackets ask for; nil = not asked
      enum Width: Sendable { case fill, fit }
      var width: Width?; var tint: RGBColor?; var textColor: RGBColor?; var fontSize: CGFloat?
      var fontWeight: FontWeightChoice?; var cornerRadius: CGFloat?; var alignment: TextAlignmentChoice?
      var isOn: Bool?; var value: Double?; var buttonLook: ButtonLook?; var hasShadow: Bool?
      var borderColor: RGBColor?; var borderWidth: CGFloat?; var opacity: Double?
      func apply(to node: inout LayerNode)
  }
  enum LookWords {
      static func look(from words: [String]) -> Look          // today's applyLook vocabulary, unchanged
      static func kind(named name: String) -> ElementKind?    // today's ScreenBlueprint.kind(named:)
  }
  enum Outline {
      /// The screen root (a column, spacing 24), sections as columns (spacing 12). When `isComplete` is false
      /// the last line is ignored (it may be half written). Never throws; never returns a half-built node.
      static func parse(_ text: String, isComplete: Bool) -> LayerNode
  }
  ```
- **The grammar** (spec §6):
  - **Line clean-up:**
    - `;` is a newline;
    - code fences and lines starting `#` are ignored;
    - a leading `- ` or `• ` is stripped.
  - **Containers:** `column:`, `row:`, `grid N:` and `card:` on a line of their own open a container. Its children are the following lines indented deeper.
    - Indentation is counted in steps of two spaces, and a tab counts as one step.
    - An indent deeper than one step below its parent counts as one step.
  - **Inline rows:** `row: a | b` puts items side by side, and indented lines under an inline row also join it.
  - **Sections:** a blank line at the top level starts a new section.
  - **Leaves:** a leaf line is `kind: words [look, …]`. A line with no known kind is text.
  - **A card** holds its children in a column (spacing 8, padding 16). `grid N` has N clamped to 1–12.
  - **Sizing** is `NaturalSize.defaultSizing(for:)`. Each node's `source` is `.generated`.
  - **Keys:** `key` is the path of `kind:ordinal` steps from the root, where the ordinal counts same-kind siblings. For example `group:0/row:0/avatar:0` is the first section's row's avatar.
  - **One primary action** (today's `withOnePrimaryAction`, on the tree):
    - one filled button is kept: the only explicitly filled one, else the first;
    - other buttons become bordered, or plain inside a row;
    - if all were bordered, the last button outside rows becomes filled;
    - plain buttons stay plain.

- [ ] **Step 1: Prove `ScreenBlueprint` unchanged before moving anything.** Run `ScreenGenerationTests`, `SiriIntentsTests`, `AssetLibraryTests` and `VoiceToolsTests`. Expected: PASS.

- [ ] **Step 2: Write the failing tests** in `OutlineTests`:
  - `theSpecsExampleParses`: the outline in spec §6 gives the expected tree of kinds and layouts:
    - root column → section → [title, row[avatar, text], card[column[text, body]], grid(2)[text, text], button];
    - the inline-row line → row[text, toggle].
  - `looksApply`: `text: Alex Tan [bold]` gets `fontWeight == .bold`; `button: Skip [plain]` gets `buttonLook == .plain`; `[red]` sets the tint.
  - `aLineWithoutAKindIsText`.
  - `fencesHeadingsAndSemicolonsAreTolerated`.
  - `anUnfinishedLastLineWaits`: `parse("title: A\nbutton: Go", isComplete: false)` has one child, a title.
  - `keysAreStableWhenLinesAreAdded`: the keys of every node from parsing N lines are unchanged in the parse of N+1 lines.
  - `awkwardIndentationIsTolerated`: tabs, three-space indents, a child indented two steps deeper, and `row: a | b` followed by an indented `c` all parse without loss. `c` joins the row.
  - `gridColumnsAreClamped`: `grid 0:` gives 1 column, and `grid 40:` gives 12.
  - `oneFilledButton`: three buttons leave one filled. A row of two buttons keeps the filled one, and the other becomes plain.
  - `theBlueprintStillReadsItsLooks`: `ScreenBlueprint.parse("button: Go [bordered, 20pt]")` gives the same item as before, with `buttonLook .bordered` and `fontSize` 20.

- [ ] **Step 3: Run them.** Run `OutlineTests`. Expected: FAIL.

- [ ] **Step 4: Implement `LookWords`**, moving the parsing out of `ScreenBlueprint`, which now calls it. Then implement `Outline`.

- [ ] **Step 5: Run the tests again.** Run `OutlineTests`, then the Step 1 suites. Expected: PASS.

- [ ] **Step 6: Commit.** `git commit -am "Outline: the indented screen outline parsed into the tree, streaming, with stable keys; look words shared with the blueprint"`

---

### Task 10: The A2UI package and Layer's catalogue

**Files:**
- Modify: `project.yml` (the package, and the two products on the `Layer` target), the committed `Package.resolved` under `Layer.xcodeproj`
- Modify: every repo doc or script that runs `xcodebuild` (find them with `grep -rln xcodebuild docs scripts Tools ci_scripts *.md`): add `-skipPackagePluginValidation`
- Create: `Layer/A2UI/LayerCatalog.swift`
- Create: `LayerTests/Fixtures/A2UI/` with eight official examples, copied from the resolved package checkout at `$HOME/Library/Developer/Xcode/DerivedData/Layer-semantic-tree/SourcePackages/checkouts/a2ui/catalogs/basic/v1/examples/`. They are renamed with an `a2ui-` prefix (test resources are flattened into one bundle). Copy:
  - `scaffold-simple-login-form`
  - `child-list-template`
  - `user-profile`
  - `product-card`
  - `modal`
  - `scaffold-row-layout`
  - `scaffold-complex-layout`
  - `music-player`

  Also create `NOTICE.md`, saying these files are from a2ui-project/a2ui at 07735d6, under the Apache License 2.0, unmodified.
- Test: `LayerTests/A2UIPackageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum LayerCatalog {
      static let id = "urn:layer:a2ui:catalog:1"
      static var basicID: String { get }                  // BasicCatalog.catalogURI(version: .v10)
      static let componentNames = ["LayerGrid", "LayerOverlay", "LayerFree", "LayerToggle",
                                   "LayerRadio", "LayerProgress", "LayerSymbol", "LayerShape"]
      /// The Basic Catalog 1.0 with Layer's components added; built once, Sendable.
      static let catalog: AnyCatalog
  }
  ```
- **Component schemas.** Each one is flat `type: object`, with `component` const, `unevaluatedProperties: false`, and child slots declared through the A2UI common types (`…/common_types.json#/$defs/ChildList`, `Child`) so that reference extraction finds them. The properties are:
  - `LayerGrid`: `children`, `columns` (integer 1–12), `columnSpacing` and `rowSpacing` (number ≥ 0), `weight`.
  - `LayerOverlay`: `children`, `horizontal` and `vertical` (`start|center|end`), `weight`.
  - `LayerFree`: `children`, `weight`.
  - `LayerToggle` and `LayerRadio`: `label` (DynamicString), `value` (DynamicBoolean), `weight`.
  - `LayerProgress`: `value` (number 0–1), `weight`.
  - `LayerSymbol`: `name` (string), `weight`.
  - `LayerShape`: `shape` (string enum of `ShapeKind` raw values), `filled` (boolean), `weight`.

  Build the catalogue with `BasicCatalog.makeCatalog(version: .v10).derive(id:components:functions:)`. Make schemas the way the SDK's own tests do (`Schema(instance:remoteSchemas: A2UICommonSchema.allSchemas)`, see `Tests/A2UICoreTests/NodeResolverTests.swift`). The research report `reports/Semantic tree 2026-11-23/recon/a2ui-sdk.md` in the main checkout (`/Users/angks/projects/personal/Layer/`) gives file and line references into the SDK.

- [ ] **Step 1: Add the package.** In `project.yml`:

  ```yaml
  packages:
    A2UI:
      url: https://github.com/a2ui-project/a2ui
      revision: 07735d6a654ae3ba25951a8753ddd57b344b1169
  ```

  Then add to the `Layer` target's dependencies:

  ```yaml
  - package: A2UI
    product: A2UISwiftCore
  - package: A2UI
    product: BasicCatalog
  ```

  Run `xcodegen generate`, then build with the test command's destination and paths, plus `build-for-testing`. Expected: BUILD SUCCEEDED. If validation of macros is refused, follow the Global Constraints. Record the build time with and without a clean package cache in the ledger.

- [ ] **Step 2: Write the failing tests** in `A2UIPackageTests`:
  - `theOfficialLoginExampleParsesAndValidates`:
    - `AgentToRendererMessage.parseAll(from:protocolVersion: .v10)` on `a2ui-scaffold-simple-login-form.json`'s `messages` gives a `createSurface` and an `updateComponents`.
    - Every component passes `PayloadValidator(catalog: LayerCatalog.catalog, config: strict v1.0)`.
  - `layersCatalogHasItsComponents`: every `componentNames` entry is in `LayerCatalog.catalog.components`, and so are all 18 basic ones.
  - `aLayerGridsChildrenAreFound`: `GraphTopologyValidator.extractReferences(from: grid, schema: …)` lists its `children` ids.
  - `anUnknownPropertyFailsStrictValidation`: a `LayerGrid` with `"colour": "red"` throws `A2UIValidationError`.
  - `theCatalogIsSendable`: validating 100 components from four `Task.detached` concurrently succeeds. That proves it can be used off the main actor.

- [ ] **Step 3: Run them.** Run `A2UIPackageTests`. Expected: FAIL (there is no `LayerCatalog`).

- [ ] **Step 4: Implement `LayerCatalog`**, and copy the fixtures and `NOTICE.md`.

- [ ] **Step 5: Run the tests.** Run `A2UIPackageTests`, then the full unit suite. Expected: PASS.

- [ ] **Step 6: Commit.** `git commit -am "A2UI: the official Swift package pinned by revision, Layer's catalogue on the Basic Catalog 1.0, and the official examples as fixtures"`

---

### Task 11: Importing A2UI

**Files:**
- Create: `Layer/A2UI/A2UIImporter.swift`, `Layer/A2UI/A2UIDiagnostic.swift`, `Layer/A2UI/A2UIIcons.swift`
- Test: `LayerTests/A2UIImportTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 8 and 10
- Produces:
  ```swift
  struct A2UIDiagnostic: Equatable, Sendable {
      enum Reason: String, Sendable { case notVersion1, parseFailed, duplicateID, noCatalog, invalidComponent,
          unknownComponent, missingRoot, cycle, unresolved, unreachable, tooDeep, binding, template,
          actionNotRun, functionNotRun, nearestKind }
      var reason: Reason; var componentID: String?; var path: String?; var message: String
  }
  struct A2UIImport: Sendable {
      struct Screen: Sendable { var surfaceID: String; var root: LayerNode }
      var screens: [Screen]; var diagnostics: [A2UIDiagnostic]
  }
  enum A2UIImporter {
      static let layerActionName = "layer.none"   // the inert event Layer's own export writes; no diagnostic for it
      /// Nonisolated; never throws. One screen per surface that has a resolvable root.
      static func importJSON(_ data: Data) -> A2UIImport
  }
  enum A2UIIcons { static func symbol(for a2uiName: String) -> String }   // SF Symbol, else Layer's symbol fallback
  ```
- **The pipeline** is spec §6, steps 1–6. It uses only the SDK's nonisolated `Sendable` APIs: `parseAll`, `PayloadValidator` and `GraphTopologyValidator.extractReferences`.
  - Layer writes its own graph walker, which collects every problem. The SDK's validators stop at the first.
  - **The screen root:**
    - If the A2UI root is a Column, it becomes the screen root.
    - Otherwise the screen root is a column holding it.
    - The screen root has kind `.group`.
  - **Every imported node:**
    - gets `source = .imported` with `key` set to the component id;
    - gets `NaturalSize.defaultSizing` unless Layer's `@metadata.extensions.layer` says otherwise;
    - goes through `TreeValidator.fixGenerated`, whose issues become `nearestKind` or `invalidComponent` diagnostics.
  - **Layer's look:** `@metadata.extensions.layer` may hold `kind` (an `ElementKind` raw value), `frame` `[x,y,w,h]`, `rotation`, `width`, `height` (Sizing JSON), `style` (Style JSON), `content`, `name`, `padding` and `layout` (Layout JSON). Whatever it holds wins over the mapping.
  - **The mapping** is the spec §6 table.

- [ ] **Step 1: Write the failing tests** in `A2UIImportTests`:
  - `theOfficialExamplesImport`: each of the eight fixtures gives at least one screen. Its diagnostics contain only these reasons: `binding`, `template`, `actionNotRun`, `functionNotRun` and `nearestKind`.
  - `theLoginFormBecomesAColumnOfFields`: the title text becomes a title (it is a `##` heading), two text fields, and a filled button with the button's Text words. The button carries an `actionNotRun` diagnostic.
  - `everyBasicComponentMapsToItsRow`: one synthetic surface holding all 18 Basic components gives the kinds of the table, row by row.
  - `aMissingVersionIsRejected` and `aMalformedEnvelopeIsRejected`: no screens, with `notVersion1` and `parseFailed`.
  - `duplicateIdsAndAMissingRootAreReported`: there is a `duplicateID`; a surface with no root makes no screen and reports `missingRoot`; the import doesn't crash.
  - `aCycleIsCutAndTheRestImported`: root → a → b → a gives a screen holding a and b once, plus a `cycle` diagnostic.
  - `unresolvedAndUnreachableAreReported`.
  - `aGraphDeeperThan50StopsThere`: a chain of 60 nested Columns gives a tree no deeper than 50 from the root, then capped at 32 by `fixGenerated`, with `tooDeep`.
  - `componentsWithoutCreateSurfaceStillImport`: an `updateComponents` with `@catalogId` on each component imports, with a diagnostic.
  - `bindingsReadTheDataModelElsePlaceholders`: `text: {"@path":"/user/name"}` with `dataModel {"user":{"name":"Ada"}}` gives "Ada". Without a data model it gives the kind's placeholder and a `binding` diagnostic.
  - `templatesExpandOverTheDataModel`: `child-list-template` with its `updateDataModel` items gives one row per item.
  - `actionsAndFunctionsAreNeverRun`: a `callRendererFunction` message reports `functionNotRun`. There is no action handler anywhere: `grep` the importer for `MessageProcessor`, `ActionHandling` and `outboundListener` in this test's comment. The test asserts the diagnostics only.
  - `iconNamesBecomeSymbolsThatExist`: every A2UI icon name in the Basic Catalog's enum maps to a name that `UIImage(systemName:)` finds.
  - `importingRunsOffTheMainActor`: `await Task.detached { A2UIImporter.importJSON(data) }.value` works.

- [ ] **Step 2: Run them.** Run `A2UIImportTests`. Expected: FAIL.

- [ ] **Step 3: Implement the importer, the diagnostics and the icon table.**

- [ ] **Step 4: Run them.** Run `A2UIImportTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -am "A2UIImporter: A2UI 1.0 parsed, validated and resolved from root into the tree off the main actor, with a diagnostic for everything it can't bring in and nothing ever run"`

---

### Task 12: Exporting A2UI, and the round trip

**Files:**
- Create: `Layer/A2UI/A2UIExporter.swift`
- Test: `LayerTests/A2UIExportTests.swift`

**Interfaces:**
- Consumes: Tasks 10 and 11
- Produces:
  ```swift
  enum A2UIExporter {
      /// createSurface (catalogId LayerCatalog.id) then one updateComponents holding every component.
      static func messages(for root: LayerNode, surfaceID: String) -> [OrderedJSON.JSONValue]
      static func jsonLines(for root: LayerNode, surfaceID: String) -> String   // one message per line
  }
  ```
- **The mapping** is the import table read backwards:
  - **Containers:**
    - a column or row group becomes a Column or Row, with `justify`, `align` and each child's `weight`;
    - a card becomes a Card whose `child` is a Column, Row or `LayerFree` for its layout;
    - a grid becomes `LayerGrid`, an overlay `LayerOverlay`, and a free group `LayerFree`.
  - **Leaves:**
    - a title becomes Text `# words`, and a body or text becomes Text;
    - a button becomes a Button whose `child` is a Text, with variant primary, default or borderless for filled, bordered or plain, and `action: {"event":{"name":"layer.none"}}`;
    - a text field becomes a TextField with `label` and `value: ""`;
    - a checkbox becomes a CheckBox, and a toggle, radio, progress, symbol or shape the matching `Layer…` component;
    - an image becomes an Image with `url ""` and `description` set to its name, and an avatar an Image with variant avatar;
    - a divider becomes a Divider.
  - **Ids:** the root is `"root"`. Every other id is `"n_"` plus the node's UUID in lower-case hex without dashes.
  - **Hidden nodes and drawings** are left out.
  - **Every component carries `@metadata.extensions.layer`** with the node's `kind`, `name`, `style`, `content`, `width`, `height` and `padding`, plus `frame` and `rotation` when its parent is free.

- [ ] **Step 1: Write the failing tests** in `A2UIExportTests`:
  - `everyExportedComponentValidates`: export the profile fixture's screen. Every component passes strict `PayloadValidator` with `LayerCatalog.catalog`, and `parseAll` reads the messages.
  - `theRoundTripKeepsTheTree`:
    - `A2UIImporter.importJSON(Data(jsonLines(profile)))` gives one screen.
    - Its root matches the original in every node's `kind`, `layout`, `padding`, sizing, `content`, `style` and `name`, and in the frames of children of free containers.
    - Ids and `source` are ignored.
    - The diagnostics are empty.
  - `aFreeSketchRoundTripsItsPlaces`: the `design-sketch` fixture's root keeps every frame.
  - `semanticNodesUseBasicComponents`: columns, rows, cards, texts and buttons export as `Column`, `Row`, `Card`, `Text` and `Button`, so another A2UI renderer can show them.
  - `hiddenNodesAndDrawingsAreLeftOut`.

- [ ] **Step 2: Run them.** Run `A2UIExportTests`. Expected: FAIL.

- [ ] **Step 3: Implement the exporter.**

- [ ] **Step 4: Run them.** Run `A2UIExportTests` and `A2UIImportTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -am "A2UIExporter: the tree written as A2UI 1.0 with Layer's look in metadata, round-tripping through the importer"`

---

### Task 13: Proving generated SwiftUI compiles, and the plan's finish

**Files:**
- Create: `scripts/check-generated-swiftui.sh`
- Create: `LayerTests/GeneratedCodeExportTests.swift`
- Modify: `Layer/Code/SwiftUICodeGenerator.swift`, only if the check finds code that doesn't compile, with a test pinning each fix

**Interfaces:**
- Consumes: today's `SwiftUICodeGenerator.files(for:settings:)` and the old model. Plan 5 switches this to the tree's fixtures.
- Produces: `scripts/check-generated-swiftui.sh`, which exits 0 only when every generated file typechecks, and prints `N files typecheck`.

- [ ] **Step 1: Write `GeneratedCodeExportTests`.**
  - It is enabled only when `ProcessInfo.processInfo.environment["LAYER_CODE_OUT"]` is set; xcodebuild forwards `TEST_RUNNER_LAYER_CODE_OUT`.
  - It builds designs with the current model:
    - one screen per device family;
    - every leaf kind, a row of three, turned elements, and a hidden element;
    - names with quotes and emoji;
    - two screens whose names clash.
  - It writes `SwiftUICodeGenerator.files(for:settings:)` for both layouts (`.stack`, `.absolute`) and both navigation-title settings, each into its own subfolder of that directory.

- [ ] **Step 2: Write `scripts/check-generated-swiftui.sh`.**
  1. Make a temporary directory.
  2. Run the test command with `-only-testing:LayerTests/GeneratedCodeExportTests` and `TEST_RUNNER_LAYER_CODE_OUT=<dir>`.
  3. In each subfolder, run `xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios27.0-simulator *.swift`.
  4. Exit non-zero on any failure, or if no files were written.

- [ ] **Step 3: Run it.** Run `scripts/check-generated-swiftui.sh`. Expected: `N files typecheck` and exit 0. If it fails:
  - fix the generator;
  - add a `DesignTests` case asserting the corrected line;
  - run it again.

- [ ] **Step 4: Run the full unit suite and the UI suite on the branch.**
  - The unit suite is the test command without `-only-testing`.
  - The UI suite uses `-testPlan Layer -only-testing:LayerUITests`.
  - Record both results in the ledger. Then run the same UI suite on main, from a temporary worktree of main, in the same simulator.
  - The set of tests failing on main is the baseline that later plans' "green" is measured against (spec, My call 19). The branch must fail no test outside it.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "A check that generated SwiftUI compiles, run from the test suite's output with swiftc; the UI baseline recorded"`

- [ ] **Step 6: Clean up the temporary worktree.** Remove the temporary main worktree and its DerivedData.
