# Rotation: design

Date: 2026-11-18. Status: awaiting approval. Branch: `feature/rotation` (worktree
`.claude/worktrees/rotation`).

Background research: `reports/Rotation grouping selection and zoom.md` and its notes in
`research_notes/Rotation grouping selection and zoom/` (in the main checkout, not committed),
especially `rotation.md` and the code audit `layer_codebase_audit.md` §1.4, §3, §10.1.

## Intent

Rotation is the first of a round of design and editing tools the user asked for on
2026-11-18 ("first is object rotation", then groups and layer order, tap-to-add selection,
a zoom ruler, image frames, corner radius, typed screen edits). Layer is an iPad app where the
Apple Pencil draws and a finger selects and edits. Today nothing on the board can be turned:
every element is an upright box. This adds turning elements, alone or several together, in
three ways: a handle, a two-finger twist, and a field in the format panel.

## Goals

1. **Everything on the board turns except screens.** Elements on screens, floating elements,
   drawings (ink), and several selected things at once. Screens (device frames) never turn.
2. **A rotate handle.** A round knob on a short stem, centred below the selected element's
   bottom edge, in the element's own axes (it turns with the element). Dragging it turns the
   element about its centre so the knob follows the finger. While turning, the angle shows next
   to the knob ("37°"). The angle snaps to every multiple of 45° when within a few degrees of
   it, with a haptic tick as it snaps. Double-tapping the knob puts the angle back to 0°.
3. **A two-finger twist, turn first.** When both fingers land on the selection and turn before
   they pinch or spread, the selection turns with them and keeps its size, with the same
   snapping and readout as the handle. When they pinch or spread first, the canvas zooms
   exactly as today. Two fingers that start anywhere else behave exactly as today.
4. **A Rotation field** in the format panel, a `NumberField` beside corner radius and opacity,
   with the ruler like every other field: a finger held on it and dragged sideways, or an Apple
   Pencil Pro squeezed while hovering over it and the barrel rolled. For this field the barrel
   turns the element **one-to-one** (roll the barrel 30°, the element turns 30°).
5. **Several things turn as one rigid piece.** The handle and the twist turn a multi-selection
   about one pivot: the centre of the selection's box, **fixed when the selection forms and
   kept until it changes**, so turning and turning back returns everything exactly where it
   was. Each member's own angle and its position both change.
6. **The selection box turns.** A single turned element shows its outline and its four resize
   handles on its turned box. Resizing a turned element works in its own axes: the corner
   opposite the dragged one stays put on the canvas.
7. **Taps, hover and lassos use the turned shape.** A tap or Pencil hover in the empty corner of
   a turned element's upright box doesn't hit it; the lasso and the selection box judge a
   turned element by its turned outline.
8. **Generated code turns too.** `SwiftUICodeGenerator` emits `.rotationEffect(.degrees(n))`
   for a turned element, and thumbnails and the share-sheet picture show the turn.
9. **Voice can turn things.** A voice tool turns an element to an angle or by an amount ("turn
   the badge 15 degrees", "straighten the logo"), and the canvas description given to the
   model includes an element's angle when it isn't 0.
10. **Each turn is one undo step**: one handle drag, one twist, one ruler scrub, one typed value,
    one voice command.

## Non-goals

- Flipping (mirror horizontally or vertically) and skewing. Flips can be added later as two
  on/off settings without changing what this design stores.
- Turning screens, and landscape screens.
- Turning with the Pencil directly on the canvas (barrel roll over an element, or a Pencil
  twist). Apple's guidance reserves barrel roll for marking, and the unmerged
  `feature/pencil-ptt` branch gives a squeeze over an element to voice. The barrel turns
  things only through the Rotation field.
- Siri / App Intents for rotation. Voice mode only, for now.
- Groups (persistent grouping) and their rotation: groups are the next piece of this round and
  will build on this one.
- Smart-guide snapping to a turned element's true slanted edges.

## Anti-goals

These would make rotation a failure even if it worked.

- **A drift.** Turning several things and turning them back must land them exactly where they
  started (tldraw, Figma and Excalidraw all drift because they recompute the pivot each
  gesture).
- **Sheared ink.** Resizing a turned drawing must stretch it along its own axes, never into a
  parallelogram.
- **A drawing that turns twice.** Erasing part of a turned drawing, or drawing a stroke that
  joins it, must leave it looking exactly as it did apart from the edit (see Constraints).
- **Canvas zoom that gets harder.** A pinch must zoom the canvas wherever it starts unless the
  fingers clearly turn first.
- **Ink drawn where it isn't.** A turned drawing's ink must be drawn where it is found (the
  2026-11-17 bug where moved ink stayed at its old place must not return).
- **Controls moved around the palette.** As agreed on 2026-11-16, nothing is repositioned to
  dodge the pencil palette.

## Constraints

Facts from the code (main at d5274ef) and the platform:

- **Model.** `DesignElement` (`Layer/Model/Design.swift`) has `frame: CGRect` (in its screen's
  points, or canvas points scaled by `scale` when floating), and optional style overrides read
  with `decodeIfPresent`. A new optional field needs no file version bump. An older build that
  opens and re-saves a file drops the field (it only writes what it knows).
- **Rendering.** Elements are placed with `.frame(...).offset(...)` in `PhoneScreenView`
  (on screens) and `FloatingElementView.placed(_:)` (floating). Thumbnails (`BoardSnapshot`)
  and the share picture reuse these views. The rotation must go between the frame and the
  offset (`.frame` → `.rotationEffect` → `.offset`), or it turns about the wrong point. Locked
  drawings are drawn by `InkPicture` inside these views; unlocked drawings live on the
  PencilKit document canvas.
- **Ink placement.** `DesignElement.canvasStrokes` (`Layer/Document/DrawingInk.swift`) places a
  drawing's saved ink: translate to origin → stretch to the frame (non-uniform) → translate to
  the frame. Rotation must be applied **after** the stretch, about the frame's centre, so the
  stretch stays in the drawing's own axes. `DrawingSync` rebuilds moved strokes with
  `PKStroke(ink:path:transform:mask:)` and compares all six transform components, so changed
  transforms already flow through.
- **The double-turn hazard.** When strokes on the canvas change (eraser, a new stroke within
  reach of a drawing), `DrawingSync.changes(for:in:reach:)` rebuilds the drawing from its
  canvas strokes with `DesignElement.drawing(_:id:)`, which measures the frame from the
  strokes' bounds and stores ink relative to it, and `Changes.apply` writes only `frame` and
  `ink`. For a turned drawing, the canvas strokes are already turned, so storing them as-is
  while the element keeps its `rotation` would turn it a second time. The rebuild must turn the
  strokes back into the drawing's own space (about its old centre), take the frame from those,
  and correct the frame's position for the centre moving, so that the drawing looks the same
  and keeps its angle.
- **Selection drawing.** `Layer/Canvas/SelectionLayer.swift` draws outlines, four corner
  handles and drag targets from upright rects; `CanvasDrags.adjust` turns a view-space drag
  into `ElementLayout.resizedKeepingShape` / `resized`, which only know upright rects. A
  multi-selection (`.several`) has a dashed outline (`groupOutline`) round the union of
  `DesignStore.canvasFrame(of:)` and no handles at all today.
- **Hit testing** is hand-written rect math in `AppModel.hoverTarget(at:)`, and lasso/box
  containment is `Enclosure.coverage(of: CGRect, by:)` (its polygon core already handles any
  shape). SwiftUI drag targets (`ElementTargets`) would follow a `.rotationEffect` on their own
  view.
- **Snapping and alignment** (`ElementLayout.snapped`, `aligned`, `distributed`,
  `SeveralThings`) work on upright rects.
- **Canvas gestures.** Two synced `PKCanvasView`s (document ink and Magic Pen sketches) are
  scroll views whose pan and pinch recognisers move the canvas; `InkCanvas` also adds a tap, a
  lasso, a long-press box, and a window-level `RestingFingerDetector` (a finger resting while
  another taps adds to the selection). A twist recogniser must hold off both canvases' pan
  and pinch while it decides, and only when both fingers start on the selection.
- **The ruler.** `Scrubber` (`Layer/Chrome/Scrubber.swift`) steps whole units: 8 pt of finger
  per unit, 10° of barrel per unit, values clamped to a range. The Rotation field needs its
  own step sizes and a value that wraps round instead of clamping. The squeeze is handled by
  one `.onPencilSqueeze` in `StylePanel`; Apple documents that every visible
  `.onPencilSqueeze` fires on a squeeze, so no second handler may be added.
- **Popover.** `SelectionActions` sits above the selection, or below when there's no room,
  and steps aside during a drag.
- **Undo.** Every change goes through `DesignStore.update`/`change`, which register undo.
- **Testing limits.** XCUITest can't make two-finger gestures or arcs (`press(forDuration:
  thenDragTo:)` is a straight line), can't produce Pencil squeeze, roll or haptics, and a tap
  finding an element doesn't prove it's drawn there (use `SketchFlowUITests.showsInk(near:)`
  or a screenshot for ink). The user's iPad mini with an Apple Pencil Pro is the device for the
  twist, the squeeze-and-roll and the haptics.

## Approaches

- **A. An angle per element, with the upright frame kept (chosen).** `DesignElement` gains
  `rotation` in degrees, clockwise, about the frame's centre; `frame` stays the upright,
  unturned box. Drawing, taps, lassos, handles and ink placement all work the turned shape out
  from the two. This matches how SwiftUI treats rotation (a render-only modifier after
  layout), how Figma and tldraw store it, and keeps X/Y/W/H, code export, align and the voice
  description reading the same simple frame.
- **B. A full transform per element.** Allows skew and flips, but everything that reads the
  frame today (format panel, align/distribute, voice, code export) would have to extract
  position and size from a matrix, and SwiftUI layout has no matrix to emit. Rejected.
- **C. Fold the turn into the frame** (frame = the box round the turned shape). Loses the real
  width and height; resizing after a turn distorts. Rejected.

## Decided by the user

- All three ways to turn: "both, handle plus twist plus the field".
- Two fingers on a selected object: **turn first**. A turn before a pinch rotates it and keeps
  its size; a pinch first zooms the canvas as today. Resizing stays on the handles.
- The implementation goes on a branch (`feature/rotation`).

## My calls (correct any of them)

- **Angle storage:** `rotation: Double?` in degrees, nil meaning 0, normalised to 0..<360,
  clockwise positive (SwiftUI's and Core Graphics' direction on screen, so no sign flip on
  export). Shown in the field as 0–359°.
- **Knob placement:** below the bottom edge in the element's own axes, on a stem of fixed
  length in screen points (so it's reachable at any zoom), with a 44 pt touch target. The
  popover places itself against the box that includes the knob, so it never covers it.
- **Snapping:** to multiples of 45° within about ±4°, with a haptic when the snap engages
  (thresholds tuned on the iPad). Snapping applies to the handle and the twist, not to the
  field.
- **The field with several selected** shows the first element's angle (as every field does in
  that case today) and setting it sets **each** element's own angle about its own centre; the
  handle and the twist turn the selection as one piece.
- **Twist thresholds:** the fingers must turn about 8° before their distance changes by about
  8% (tuned on the iPad). Fingers count as "on the selection" when they are inside the
  selection's outline.
- **The finger ruler for rotation:** about 1° per 2 pt of drag (so a quarter turn is a short
  drag), the barrel one-to-one, and the value wraps round at 360.
- **A multi-selection's outline** is drawn turned when every member has the same angle (for
  example after turning several upright things together), otherwise as the upright box round
  their turned shapes (tldraw's rule). It gets the knob, never resize handles (as today).
- **The pivot** is fixed when the selection forms (set, extended or reduced) and forgotten when
  it changes. Moving the selection moves the pivot with it. It is the centre of the whole
  selection's outline, locked members included (the knob hangs off that outline).
- **No drift from rounding:** non-drawing elements' origins are rounded to whole points when
  several things are positioned (`SeveralThings.position`). A multi-selection's turn is
  therefore always computed from the members' frames and angles as they were when the
  selection formed (the baseline, kept with the pivot) plus the total turn so far, never
  step by step from the last rounded result.
- **The knob on a multi-selection** reads the turn since the selection formed (starting at
  0°). Double-tapping it turns the selection back to 0°, which puts every member back exactly
  where it was when the selection formed (positions and angles, from the baseline).
- **Stack-layout code export** (the default "Stack" mode, which spaces rows from each
  element's upright frame) turns a turned element in place with `.rotationEffect` after its
  frame, and leaves the spacing as if it were upright. That matches the canvas, where a turned
  element doesn't push its neighbours either. "Exact Positions" mode uses `.frame` →
  `.rotationEffect` → `.offset`.
- **Screens in a multi-selection:** when the selection includes a screen, there is no knob, the
  twist does nothing, and the Rotation field is hidden.
- **Locked things** don't turn: a locked element shows no knob, the field is disabled, and in a
  multi-selection its locked members stay put while the rest turn (the same rule as moving).
- **Members keep their hosts:** turning several things never moves an element to another screen
  or off its screen, even if it ends up overhanging the screen's edge.
- **A turned drawing keeps its angle** when its ink is edited (erased, or joined by a new
  stroke). New strokes joining it are turned into its own space.
- **Format panel X/Y/W/H** keep showing the element's own upright frame, which is what code
  export uses; they don't change when it turns.
- **Align, distribute and smart guides** use the upright box round each element's turned
  shape.
- **The popover and the Layers panel** need no new controls: rotation lives on the canvas and in
  the format panel.
- **Voice:** one tool, `rotateElement`, taking an element handle and either an absolute angle or
  a turn by a signed amount; "straighten" is an absolute 0. The canvas description lists
  `rotation` only when it isn't 0, to save tokens.
- **Accessibility:** the selection gets VoiceOver custom actions "Rotate 15° clockwise",
  "Rotate 15° counterclockwise" and "Reset rotation"; the Rotation field is adjustable like
  the other number fields.

## Edge cases

| Case | Behaviour |
|---|---|
| Turning a text element, then editing its text | The text stays turned; editing happens in the popover as today. |
| Resizing a turned element from a corner | The opposite corner stays fixed on the canvas; the element's own W/H change. |
| Resizing a turned drawing | Stretches along the drawing's own axes; no shear. |
| Erasing part of a turned drawing | It keeps its angle and its remaining ink stays exactly where it was. |
| A new stroke within reach of a turned drawing | Joins it, as today; the drawing keeps its angle. |
| Turning several things, then turning them back | Everything returns exactly to where it was. |
| Turning several things, then moving them, then turning again | The pivot moved with them; no drift. |
| Duplicating a turned element | The copy has the same angle (the whole element value is copied). |
| Two fingers land on the selection and pinch | The canvas zooms, as today. |
| Two fingers land half on, half off the selection | Not a twist; the canvas behaves as today. |
| A finger rests on a selected element and another taps a different one | Adds it to the selection, as today; not a twist. |
| The canvas is locked (Lock Canvas) | The twist still turns the selection; only canvas pan/zoom is locked. |
| Undo after a twist | The whole twist is undone in one step. |
| A file with turned elements opened by an older Layer build | Opens upright; re-saving there drops the angles. |
| Magic Pen ink | Unaffected: sketches are on their own canvas and aren't elements. |
| A turned image or button exported to code, Exact Positions | `.frame` → `.rotationEffect(.degrees(n))` → `.offset`, matching the canvas. |
| A turned element exported to code, Stack (default) | Turned in place after its frame; rows and gaps spaced as if it were upright. |
| Double-tapping the knob of a multi-selection | Everything goes back exactly to where it was when the selection formed. |

## Left to the builder

- The geometry helper (a turned-rect type with corners, contains, upright bounds) and where it
  lives.
- How the twist recogniser is built (a `UIGestureRecognizer` subclass on the canvas container,
  its relationship to both canvases' pan and pinch recognisers and to `RestingFingerDetector`),
  within the turn-first rule.
- Which haptic generator plays the snap tick.
- How `Scrubber` gains per-field step sizes and wrapping, without changing how other fields
  behave.
- The knob's look (system styling, matching the existing handles) and the readout's position.
- How undo is grouped for continuous gestures (follow how moving and resizing do it today).
- Tests: unit tests for the geometry (hit test of a turned rect, upright bounds, resize keeping
  the opposite corner, several turning and turning back with no drift, ink placement with no
  shear, the double-turn rebuild, angle normalisation and snapping), the code generator's
  output, a file round-trip with and without `rotation`, the voice tool and canvas
  description, the twist's turn-versus-pinch classifier on synthetic touch tracks; UI tests for
  the field and a straight drag on the knob, with a pixel or screenshot check that turned ink
  is drawn where it is; and a device checklist for the twist, the snapping haptic and the
  squeeze-and-roll on the field.
