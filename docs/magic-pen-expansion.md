# Magic Pen: more components, better reading, better styling

Notes on where the Magic Pen stands today and how to grow it: which components to add,
how to tell their doodles apart, and how to make what it produces look designed rather
than placed.

---

## 1. How it works today

```
strokes ─► SketchAnalyzer.cluster ─► SketchAnalyzer.observe ─► SketchRequest.candidates
                                                                      │
              ElementLayout.frame ◄─ DesignStore.addElement ◄─ SketchEngine.read
                                                              (rules, then Apple
                                                               Intelligence for
                                                               close calls)
```

| Stage | File | What it does |
|---|---|---|
| Grouping | `Sketch/SketchAnalyzer.swift` `cluster` | Strokes whose bounds come within 14 pt of each other form one sketch. |
| Geometry | `SketchAnalyzer.observe` | Reduces a group to one of six forms: `enclosure(roundness, inner: none/cross/other)`, `wave(humps)`, `stackedLines(count)`, `line`, `scribble`, `scratch(passes)`. |
| Meaning | `Sketch/SketchInterpreter.swift` `candidates` | A `switch` over form × placement × aspect ratio × size picks 1–3 candidate `ElementKind`s. |
| Choice | `Sketch/RuleInterpreter.swift`, `SketchEngine.swift` | One candidate wins outright; a close call goes to the on-device model with a text description, restricted to the candidates. |
| Placement | `Model/ElementLayout.swift` | Each kind gets a fixed standard size, is centred across the screen, and keeps only the sketched height. |
| Look | `Model/ElementStyle.swift`, `Canvas/PhoneScreenView.swift` | Fixed per-kind defaults: one accent colour, centred text, 13 pt grey body. |

Sketchable today: title, body, image, button, text field, divider, toggle, avatar (on
screens); screen, sticky note, text (on the open canvas); scratch-out to delete.
`symbol` exists as a kind but you can't sketch it.

### What limits accuracy and breadth

1. **The inside of a shape is mostly ignored.** `InnerMark` is `none`, `cross`, or
   `other`, and `other` is never used in `candidates`. An empty box and a box with a label
   squiggle in it read the same, and there's no way to say "box with a chevron" or
   "pill with a knob". This is the biggest single limit, because most UI components are a
   container plus a small mark inside it.
2. **Six forms can't represent small glyphs.** Chevrons, ticks, plus signs, triangles,
   dots, stars, vertical lines and arrows all become `scribble` (or are dropped as under
   16 pt). That rules out icons, checkboxes, back buttons, play buttons and page dots.
3. **Clustering is all or nothing.** Anything within 14 pt merges, so you can't draw a
   button inside a card, and a row of tab icons can merge into one blob or split
   unpredictably. Timing isn't used, and neither is drawing over an existing element.
4. **First match wins, with no scores.** `candidates` is a hand-ordered `switch`, and
   `isCloseCall` is a separate set of hand-written conditions. Each new kind adds more
   branches to both, and they can drift apart.
5. **Layout throws away what was drawn.** Widths are fixed (title 228, body 297, button
   353), so two half-width buttons drawn side by side become two overlapping full-width
   buttons. Only toggle, avatar and symbol keep their x position. Vertical spacing snaps
   to 4 pt but ignores the neighbours.
6. **The model only gets words.** `SketchRequest.renderImage()` exists but nothing calls
   it. The prompt describes only the six forms.
7. **Each kind is spread across ~8 switches**: `Design.swift` (name, symbol,
   placeholder), `ElementStyle`, `ElementLayout`, `PhoneScreenView`,
   `SwiftUICodeGenerator` (twice), `SketchPrompt.name`, and the `reading(namedIn:)` word
   list. Adding 20 kinds means 160 edits.

---

## 2. Components to add

Each doodle below uses the usual paper-wireframing conventions where they exist, and is
chosen so it doesn't collide with the existing doodles. The **Needs** column says which
analyzer capability from §3 each one depends on: **A** inner parts, **B** glyphs,
**C** repetition/dividers, **D** containers, **E** fill/hatching.

### Controls

| Component | Doodle | Tells it apart from | SwiftUI output | Needs |
|---|---|---|---|---|
| Checkbox | Small **sharp-cornered** square (< ~8% of screen width), empty or with a tick | Avatar (round); a small box today, which reads as image | `Toggle` with a `checkmark.square` style, or `Image(systemName:)` | B for the tick |
| Radio button | Small circle with a **dot** in the centre | Avatar (empty circle, or larger than ~32 pt) | Custom `Image(systemName: "largecircle.fill.circle")` | A |
| Toggle (improve) | Pill with a **knob circle** at one end; knob on the right means on | Plain pill (button / chip) | `Toggle` with `isOn` from the knob's side | A |
| Slider | Horizontal **line with a small circle** on it | Divider (line only) | `Slider` with the value taken from the knob's position | A (line + knob) |
| Stepper | Small box with **– and +**, or split by one vertical line | Segmented (wider, more segments) | `Stepper` | B or C |
| Segmented control | Wide rounded box **split by 1–3 vertical lines** | Text field / button (no dividers) | `Picker` with `.pickerStyle(.segmented)` and n+1 segments | C |
| Picker / menu | Wide box with a **down chevron (v)** at the trailing end | Text field (nothing inside, or a leading squiggle) | `Picker` with `.menu`, or `Menu` | A + B |
| Search field | Box or pill with a **magnifier (small circle and tail)** at the leading end | Text field, button | `TextField` with `magnifyingglass`, or `.searchable` | A + B |
| Text area | Tall box with **lines inside running from the leading edge** | Image (cross), card (mixed contents) | `TextEditor` | A |
| Progress bar | **Very thin**, long box (height < ~12 pt), partly hatched | Text field (taller) | `ProgressView(value:)` with the hatched fraction | E |
| Link / text button | Squiggle with an **underline** | Title / body | `Button` with `.buttonStyle(.plain)`, tinted | A (line under wave) |
| Chip / tag | Small pill **with a squiggle inside**, often several in a row | Toggle (empty, or with a knob) | `Text` in a `Capsule` background | A, C for rows |
| Floating action button | Circle with **+** inside, near the bottom trailing corner | Avatar, radio | `Button` with a `plus` circle and a shadow | A + B |
| Rating | Row of **stars** | Page dots | `HStack` of `star.fill` | B + C |

### Navigation and structure

| Component | Doodle | Tells it apart from | SwiftUI output | Needs |
|---|---|---|---|---|
| Navigation bar | **‹** chevron near the top leading corner, optionally with a squiggle beside it | Symbol (if not top-leading) | `NavigationStack` with `.navigationTitle` and a toolbar | B + position |
| Tab bar | Full-width box or line in the **bottom band** with **3–5 small marks** in a row | Button (empty, or one squiggle) | `TabView` with that many tabs | C + position |
| Sheet | Full-width box anchored to the bottom with a **short grabber line** at the top centre | Card, image | `.sheet` with `.presentationDetents` | A + position |
| Alert | Centred box with a squiggle and **two small boxes** along its bottom edge | Card | `.alert` | D |
| Card | Large rounded box with **mixed contents** (image cross, squiggles, button) | Image (cross only), text area (lines only) | `VStack` in a rounded background | D |
| List | Box **divided by horizontal lines** into rows, or **3+ identical stacked rows** (circle + squiggle) | Body text (lines, no box) | `List` / `ForEach` with n rows | C |
| Grid | **2×2 or larger** grid of similar boxes | Several images | `LazyVGrid` | C |
| Carousel / page control | Image box with a **row of 3–5 dots** under it, or dots alone | Body text | `TabView` with `.tabViewStyle(.page)` | C |
| Icon (symbol) | Small glyph (< ~44 pt): heart, star, gear, bell, plus, x, chevrons, hamburger (3 **short** stacked lines) | Body (3 **long** stacked lines) | `Image(systemName:)`; the kind exists already | B |

### Media and data

| Component | Doodle | Tells it apart from | SwiftUI output | Needs |
|---|---|---|---|---|
| Video | Box with a **triangle (play)** in it | Image (cross) | `VideoPlayer` placeholder | A + B |
| Map | Box with a **pin / teardrop** in it | Image | `Map()` | A + B |
| Chart | **L-shaped axes** with bars or a line inside | Image, divider | Swift Charts `Chart` with sample data | B + C |
| Badge | Tiny circle overlapping an element's **corner** | Radio | `.badge` / overlay | Drawing over an element |

**Suggested order:** start with checkbox, radio, toggle knob, progress bar, link, the
hamburger icon and side-by-side buttons. They need little new analysis. Next do picker,
search, segmented, slider, stepper, FAB, chips, nav bar, tab bar and sheet. They need
inner parts and glyphs. Leave list, grid, card, carousel, alert, chart, map and video for
last, because they need containers in the data model.

---

## 3. Telling the doodles apart

### A. Describe what's inside a shape, recursively

Replace `InnerMark` with a list of the parts inside, each observed in its own right and
placed relative to the container:

```swift
struct InnerPart: Sendable, Equatable {
    var observation: SketchObservation   // its own form: glyph, wave, line, enclosure…
    var anchor: Anchor                   // leading / centre / trailing × top / middle / bottom
    var relativeSize: CGSize             // fraction of the container
}
case enclosure(roundness: Double, parts: [InnerPart])
```

The existing outline-versus-inner split in `enclosure(_:in:)` already separates the parts.
Cluster the inner strokes and call `observe` on each cluster. Then every compound
component is the same kind of statement: *wide box + leading magnifier = search*,
*wide box + trailing chevron = picker*, *pill + end knob = toggle*, *box + centred wave =
labelled button*, *box + leading wave = text field with placeholder*, and so on. The words
inside also give you the element's text length for free.

### B. Recognise small glyphs with a template matcher

Add a `glyph(Glyph, confidence)` form for anything under ~44 pt, recognised with the
**$P / $Q point-cloud recognizer**. It's about 200 lines, runs on the device, needs no
training, and doesn't care about stroke order or direction. A vocabulary of about 15
covers most of §2: tick, x, plus, minus, ‹ › ˅ ˄, triangle, star, heart, magnifier, pin,
dot, hamburger, gear and bell. Store the templates as JSON so adding one doesn't need code.
Lower the 16 pt floor in `observe` for groups that match a glyph confidently, so that
dots and ticks survive.

Cheaper features worth adding for every form:

- **Corner count** from Douglas–Peucker simplification plus a turning-angle threshold.
  It tells triangle, square, star and circle apart, and is more robust than `roundness`
  alone.
- **Ink density**: ink length ÷ bounding area. This separates hatched or filled shapes
  (primary button, progress fill) from outlines (secondary button).
- **Straightness and orientation per stroke.** Vertical lines are needed for segmented
  controls and steppers; today only a single horizontal line is recognised.

### C. Find repetition and dividers

After clustering, look across groups for **2+ groups with similar observations aligned on
one axis** (same height within ~20%, evenly spaced). That gives a row (chips, tab items,
rating stars, page dots, buttons side by side) or a column (list rows, stacked text
fields). Inside an enclosure, **straight lines spanning its full height or width** become
segment or row dividers. That covers segmented control, list and stepper.

### D. Smarter grouping

- **Time and containment, not only distance.** Strokes drawn within ~1 s of each other,
  or entirely inside the outline that is being drawn, join it. Keep a newly drawn outline
  separate from an *existing element* it sits inside, so that a button can be drawn into
  a card.
- **Drawing on an existing element changes it.** A tick in a checkbox checks it, a knob
  moved to the other end flips a toggle, hatching a button makes it primary, a chevron
  added to a text field turns it into a picker, and a tiny circle on a corner adds a
  badge. Route these through the existing `scratchedOutBy`-style hit test before reading
  the sketch as something new.

### E. Score candidates instead of picking the first match

Turn the `candidates` switch into a table of rules, each returning a score:

```swift
struct ComponentRule {
    var kind: ElementKind
    var placement: PlacementFilter           // on screen / open canvas / top band / bottom band
    var score: (SketchObservation, Context) -> Double   // 0…1
}
```

Sort by score. When the top two are within a margin (say 0.15), it's a close call for the
model. That replaces both `candidates` and `isCloseCall` with one mechanism, and a new
component is one more rule.

Put **context priors** into the scores rather than into branches:

- **Position.** The top band favours nav bar and title, the bottom band favours tab bar,
  primary button and FAB, and the top leading corner favours back.
- **Neighbours.** A text field above favours another text field. A primary button
  already present makes the next button secondary.
- **Counts.** One title, one tab bar and one nav bar per screen.
- **Drawn width.** A half-width box next to another half-width box is a button row.

### F. Give the model more to go on

- Describe **parts** ("a wide box with a small circle at its leading end") using §3A. A
  small model reads a structured description well.
- Send `renderImage()` to any provider that accepts images, such as a hosted vision
  model. Add a `supportsImages` flag on `SketchProvider` and attach the picture when it's
  set. The description stays as a fallback.
- Generate the "What designers usually mean" list from the rule table, **including only
  the kinds among this sketch's options**, so the prompt stays short as the vocabulary
  grows.

### G. Learn from corrections, and measure

- **"Did you mean…" pill.** For a second or two after a conversion, show the runner-up
  as a single tap. It's cheap, it's undoable, and it hides most misreads.
- **Log corrections on the device.** When someone changes an element's kind right after
  conversion, keep `(observation features, read as, changed to)`. Use it to tune
  thresholds; nothing needs to leave the device.
- **Stroke corpus and confusion matrix.** Record real strokes for each component as JSON
  fixtures, and have `SketchReadingTests` (35 tests today) print accuracy per kind and the
  most common confusions. Run it on every rule change, so a new kind can't silently take
  hits from an old one.

---

## 4. Styling and design

### Issues in the current defaults

| Today | Problem | Suggestion |
|---|---|---|
| Body is 13 pt `#8E8C86`, centred | Contrast is about 3.4:1 on a white screen, below WCAG AA's 4.5:1, and 13 pt is footnote size | 17 pt body in `label`; keep grey (`secondaryLabel`) for captions only |
| Title is `frame.height × 0.7`, bold, centred | Arbitrary sizes, and iOS screens are usually leading-aligned | Snap to the iOS type scale by drawn height: Large Title 34, Title 28, Title 2 22, Headline 17. Leading alignment unless the sketch was drawn centred |
| Fixed widths (title 228, body 297, button 353) | Ignores what was drawn; side-by-side buttons overlap | Keep the drawn width when it's under ~70% of the content width; snap to a 2- or 3-column grid with a 12 pt gutter |
| y snapped to 4 pt | No rhythm between elements | Snap the gap to the element above to 8 / 16 / 24 when within ±6 pt; snap leading edges to existing ones |
| One accent for every button | Every button looks primary | Variants: **filled** (hatched doodle, or the first button), **bordered** (empty outline, or later buttons), **plain** (underlined squiggle), **destructive** (if the label says delete) |
| Text field is a flat grey fill | Fine, but only one look | Field styles: filled / outlined / underlined, chosen per board |
| Placeholders "Placeholder", "Continue" | Every screen reads the same | Context copy: the 1st/2nd text field on a screen with a "Sign in" button becomes Email / Password; use the model (as `suggestTitle` does) to write coherent copy for the whole screen in one call |

### Add a board-level design system

The biggest styling improvement is to stop storing raw values per element and refer to
**tokens**:

```swift
struct DesignTokens: Codable {
    var accent: RGBColor
    var neutrals: Palette            // label, secondary, tertiary, fill, separator, background
    var typeScale: TypeScale         // largeTitle…caption, mapped to Dynamic Type styles
    var radius: RadiusScale          // small 8 · medium 12 · large 20 · full
    var spacing: [CGFloat]           // 4 8 12 16 24 32
    var buttonStyle: ButtonLook      // filled / tinted / bordered / glass
    var fieldStyle: FieldLook        // filled / outlined / underlined
}
```

- Keep it in `CanvasSettings` next to `code`, so it's saved with each board. Offer a few
  presets in the Style panel: *iOS Default*, *Liquid Glass*, *Soft* (large radii, tinted
  fills), *Editorial* (serif titles, hairline borders), *High Contrast*.
- Elements keep a **role** (`.primary`, `.secondary`, `.caption`…) and per-element
  overrides on top, as `ElementStyle` does now. Changing the theme restyles every screen.
- `SwiftUICodeGenerator` writes the tokens as idiomatic SwiftUI (`.font(.title2)`,
  `.buttonStyle(.borderedProminent)`, `.buttonStyle(.glass)`, `.tint(…)`,
  `Color(.secondaryLabel)`) instead of literal sizes and hex values, so the generated code
  supports Dynamic Type and dark mode for free.
- Add **light/dark** and **Dynamic Type size** preview toggles on screens. This becomes
  possible once the colours are semantic tokens.

### "Tidy screen"

`ScreenBlueprint` already lays out sections the way a person would (it's used by Siri).
Add an action, or do it automatically after N sketches, that turns a sketched screen into
a blueprint (group elements into rows by y overlap and sections by large gaps) and lays it
out again with the token spacing. Sketches stay loose while you draw, and the result
ends up on a grid.

---

## 5. Structural changes these depend on

1. **One spec per component.** Collect the per-kind switches into a `ComponentSpec`
   registry: name, SF Symbol, placeholder, default size and sizing rule, style defaults,
   sketch rule(s), prompt name and description, renderer, and codegen. `ElementKind` stays
   the `Codable` key. Adding a component then means one new file plus fixtures.
2. **Element data for components with state.** Add optional fields, decoded with
   `decodeIfPresent` as the existing ones are: `items: [String]?` (segments, tabs, list
   rows, chips), `value: Double?` (slider, progress, rating), `selectedIndex: Int?`,
   `variant: String?` (button or field style), and `role`.
3. **Containers.** Card, list, sheet, alert and tab bar hold other elements. Either add
   `children: [DesignElement]?` or a `parentID`. The layers panel, hit-testing, scratch-out
   and the stack code generator all have to understand nesting. This is the largest
   change, so leave it until last.
4. **Forward compatibility.** Decode an unknown `ElementKind` raw value as a placeholder
   instead of failing, so files made by a newer build still open in an older one.
