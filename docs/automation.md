# Automating Layer

Every edit you can make on the canvas by hand can also be made through Layer's App Intents: in Shortcuts, through Siri, and (once the Siri AI preview SDK is in, see `SiriAIPreview/README.md`) as tools a language model calls. This page lists those actions, their units and their text formats. It's written for someone building a model integration, and for the model itself.

All the actions are in `Layer/Intents/`. Each change goes through `DesignStore` exactly as a change made by hand does, and undoes as one step.

## Coordinates

- **Screen points.** An element's frame on a screen is in that screen's own points, measured from its top-left corner. An iPhone screen is 393 × 852 and its safe area starts 59 points down. These are the same units the generated SwiftUI uses.
- **Canvas points.** A screen's `x`/`y` and loose elements (sticky notes, and text placed with On Canvas) are in canvas points. A screen at scale 50 % takes up half its size in points on the canvas.
- **Get Design Layout** returns every screen's canvas position, scale, device size and safe area, and every element's frame, so a model can look before it acts.

## Actions

| Area | Action | What it does |
|---|---|---|
| Read | **Get Design Layout** | Returns the design as JSON: screens, elements with frames and look, loose elements, canvas settings and ink. Element `id`s are entity identifiers. |
| | Describe Design, Find Designs / Screens / Elements | Return the design in words, or find things by name. |
| Screens | **Add Screen** | Device, name and, optionally, canvas `x`, `y` and `scale` (%). |
| | **Build Screen** | A whole screen from a description: one element per line (see below). |
| | **Move or Scale Screen** | Canvas `x`, `y`, `scale` (%). |
| | **Lock or Unlock Screen**, Rename, Change Device, Duplicate, Delete, Show | |
| Elements | **Add Element** | Any of the 14 kinds, with text, symbol, colour, a **Look** string, and optional `x`, `y`, `width`, `height`. With **On Canvas** it goes on the open canvas, at canvas points. |
| | **Add Picture** | An image file or photo as an image element, at an optional frame, or as the new picture of an existing image. |
| | **Style Element** | Look string; fill, text and outline colour (named or hex); font size and weight; alignment; corner radius; opacity; outline width; shadow; **on/off**; **progress**; **button style**; **SF Symbol**. |
| | **Move or Resize Element** | `x`, `y`, `width`, `height`: screen points, or canvas points for loose elements. |
| | **Move Element to Screen** | Onto another screen or off onto the canvas, at an optional `x`/`y`. |
| | Change Text, Align, Change Order, Duplicate, Delete, Hide or Show, Lock or Unlock, Rename, Select | |
| Canvas | **Change Canvas Settings** | Grid, grid style and spacing, snapping, frame names, spacing guides, background (named or hex), device for sketched screens, code layout, `#Preview`, navigation title, Magic Pen convert-after-pause and scratch-out. |
| | **Set Canvas View** | Zoom (%), centre `x`/`y` in canvas points, lock against touch. |
| | Zoom to Fit, Undo, Redo | |
| Ink | **Draw Strokes** | Strokes drawn with the Magic Pen (read into elements) or with a pen, monoline, marker or pencil (kept as ink). Returns the design afterwards. |
| | **Erase Ink** | Ink touching an area, or all of it. |
| | Convert Sketches, Clear Sketches | Read waiting Magic Pen sketches now, or throw them away. |

## Look words

**Build Screen**'s square brackets, and the **Look** parameter of Add Element and Style Element, take comma-separated words:

| Words | Sets |
|---|---|
| `blue`, `#0A84FF` | Fill colour |
| `text white`, `text #333333` | Text colour |
| `regular`, `medium`, `semibold`, `bold` | Font weight |
| `18pt` | Font size |
| `radius 12` | Corner radius |
| `fill`, `fit` | Width in Build Screen: stretch across, or keep the usual size |
| `on`, `off`, `checked`, `unchecked`, `selected` | Toggles, checkboxes, radio buttons |
| `40%` | How full a progress bar is |
| `filled`, `bordered`, `plain` | Button style |
| `left`, `centre`, `right` | Text alignment |
| `shadow`, `no shadow` | Shadow |
| `border red`, `border 2` | Outline colour or width |
| `opacity 50%` | Opacity |

```
title: Create account
text field: Email
text field: Password
row: checkbox [off] | text: Remember me [left]
progress [40%]
button: Sign up [blue, bold, radius 12]
button: I have an account [plain]
```

Kinds: title, body, button, text field, image, symbol (`symbol: heart.fill`), divider, toggle, checkbox, radio, progress, avatar, text, sticky note.

## Strokes

**Draw Strokes** takes one stroke per line, or several split by `;`. A stroke is either freehand `x,y` points or a named shape. Lines starting with `#` or `//` are comments.

| Line | Draws |
|---|---|
| `20,40 120,40 120,90` | Freehand, through the points in order |
| `box x y w h [radius]` | A rounded box |
| `pill x y w h` | A box with fully round ends |
| `circle cx cy r`, `oval x y w h` | A circle or an ellipse |
| `line x1 y1 x2 y2 …` | A straight polyline |
| `wave x y w h [humps]` | A squiggle |
| `cross x y w h` | Two diagonals (two strokes) |
| `tick x y w h` | A check mark |
| `dot cx cy [r]` | A dot |
| `scribble x y w h [passes]` | Back and forth: a scratch-out |

A JSON array of strokes, each an array of `[x, y]` or `{"x":…, "y":…}` points, works too.

With **Coordinates** set to screen points (the default) the strokes are measured from a screen's top-left corner. Sketching a new screen, or drawing beside the screens, needs canvas points.

With the **Magic Pen**, strokes are read as a hand-drawn sketch: a tall rectangle becomes a screen, a short tall zigzag a title, long low waves body text, a box with a cross an image, a rounded bar a button, a small pill a toggle, a small circle an avatar, a tiny square a checkbox (ticked with a tick inside), a tiny circle a radio button (selected with a dot), a long thin box a progress bar, and a scribble over an element deletes it. With any other pen the ink stays as drawn; give **Read As**, such as "a button saying Sign up", to have that ink read with the description in mind.

Strokes that touch or sit close together are read together, as one sketch, just as they are when drawn by hand. So draw one thing per call, and wait for each call to return before the next: first the screen, then each element on it. A login screen, one call per line:

```
box 100 80 260 560 26                               canvas points: becomes an iPhone screen
wave 150 112 96 40 3                                screen points from here on: a title
box 34 186 326 364 46; cross 34 186 326 364         an image
wave 52 588 290 28 8                                body text
pill 28 738 337 60                                  a button
```

These are the sketches the scripted demo draws (`Layer/Debug/DemoScript.swift`).

Each call returns the design's contents afterwards, so the caller can check what each sketch became. For a screen whose contents are already known, **Build Screen** is faster and exact.

## Not covered yet

- Handwritten words. Text is set on the element with Change Element Text or with Build Screen, not drawn.
- Selecting several things at once. Each action works on one element or one screen.
