# Automating Layer

Every edit you can make on the canvas by hand can also be made through Layer's App Intents: in Shortcuts, through Siri, and (once the Siri AI preview SDK is in, see `SiriAIPreview/README.md`) as tools a language model calls. This page lists those actions, their units and their text formats. It's written for someone building a model integration, and for the model itself.

All the actions are in `Layer/Intents/`. Each change goes through `DesignStore` exactly as a change made by hand does, and undoes as one step, in the design's history and in the system's (Siri's own Undo).

## Coordinates

- **Screen points.** An element's frame on a screen is in that screen's own points, measured from its top-left corner. An iPhone screen is 393 × 852 and its safe area starts 59 points down. These are the same units the generated SwiftUI uses.
- **Canvas points.** A screen's `x`/`y` and loose elements (sticky notes, and text placed with On Canvas) are in canvas points. A screen at scale 50 % takes up half its size in points on the canvas.
- **Get Design Layout** returns every screen's canvas position, scale, device size and safe area, every element's frame, and every container with what it holds, so a model can look before it acts.
- **Frames are what is seen.** An element in a container, a turned one included, is given as the upright box round its middle on its screen (or on the canvas), with the angle it is seen at as `rotation`. Hand the numbers Get Design Layout gave back to Move or Resize Element and nothing moves.

## The design's tree

A screen holds elements and containers, and a container holds more of either, nested up to 32 deep, up to 5,000 things in a design. The containers are the ones the Layers panel shows: a **group**, a **card**, and a group or card laid out as a **row**, **column**, **grid** (1 to 12 columns) or **overlay**. A screen's own root can be laid out too: a generated screen is a column.

- **Elements are the leaves.** Siri's element queries, Find Elements and Get Design Layout's `elements` list only the things you can see and style: titles, buttons, images and the rest. A container isn't an element: a selected one is invisible to Siri. An element in a locked or hidden container is locked or hidden itself.
- **Get Design Layout** keeps every key it had before containers, so a shortcut that read it reads it still, and adds:
  - on each element: `parent` (its container's id, left out on a screen's root), `sizing` (`width` and `height`, each with its `mode`: `fixed`, `fit` or `fill`) and `rotation` (left out when upright);
  - on each screen: `deviceName`, `layout` and `padding` (how its root lays out what it holds), and `containers`, each with the keys an element has plus `layout`, `padding` and `children` (its children's ids, in order);
  - at the top, `canvasContainers` for the open canvas, and in `canvas`, `newScreenDeviceName`.
  - `device` and `newScreenDevice` are the device's id: `iphone`, `ipad` and the others, or `custom-…` for one of the design's own.
- **What a row, column or grid holds is placed by it.** Move or Resize Element with a position moves such a child as a drag would: to the place in a row, column or grid on its screen where its middle lands, or, when that is in none, out onto its screen at the position, fixed at its size. A size alone resizes it where it is. Under a screen whose root is a column there is nowhere to take it out to, and a position that lands in its own place changes nothing: both throw the `laidOut` error below, and nothing is changed. Change Element Order throws `laidOut` for a row's, column's or grid's child. Move Element to Screen takes anything out of its container onto the other screen.
- **Align lines a laid-out child up by its container**, as Align in the Format panel and voice's `alignElement` do: a child of a row, column, grid or overlay, a laid-out screen root's included, sets that container's alignment. A column takes the left edge, horizontal centre and right edge; a row the top edge, vertical middle and bottom edge; a grid or an overlay any of them. One the container has no use for, such as the top edge in a column, throws `alignmentNotTaken` and changes nothing. An element in a free container or on a free screen lines up with its screen.
- **Add Element on a laid-out screen** adds the element last in the column; X and Y are passed over, and a width or height given is kept.

## Actions

| Area | Action | What it does |
|---|---|---|
| Read | **Get Design Layout** | Returns the design as JSON: screens, elements with frames and look, the containers that hold them, loose elements, canvas settings and ink. Element `id`s are entity identifiers. |
| | Describe Design, Find Designs / Screens / Elements | Return the design in words, or find things by name. |
| Screens | **Add Screen** | Device or **Custom Device**, name and, optionally, canvas `x`, `y` and `scale` (%). |
| | **Build Screen** | A whole screen from a description: one element per line, with containers and sections, or A2UI JSON (see below), on a Device or Custom Device. Says what it couldn't bring in or put right, such as "1 thing runs off the screen". |
| | **Move or Scale Screen** | Canvas `x`, `y`, `scale` (%). |
| | **Change Screen Device** | Device or **Custom Device**. What is on the screen is laid out for the new size. |
| | **Lock or Unlock Screen**, Rename, Duplicate, Delete, Show | A duplicate keeps its screen's device. |
| Elements | **Add Element** | Any of the 14 kinds, with text, symbol, colour, a **Look** string, and optional `x`, `y`, `width`, `height`. With **On Canvas** it goes on the open canvas, at canvas points. |
| | **Add Picture** | An image file or photo as an image element, at an optional frame, or as the new picture of an existing image. |
| | **Style Element** | Look string; fill, text and outline colour (named or hex); font size and weight; alignment; corner radius; opacity; outline width; shadow; **on/off**; **progress**; **button style**; **SF Symbol**. |
| | **Move or Resize Element** | `x`, `y`, `width`, `height`: screen points, or canvas points for loose elements. In a row, column or grid, see "The design's tree". |
| | **Move Element to Screen** | Onto another screen or off onto the canvas, at an optional `x`/`y`, out of any container it was in. |
| | **Align Element** | Lines it up with an edge or the middle of its screen. In a row, column, grid or overlay, sets that container's alignment instead: see "The design's tree". |
| | **Change Element Order** | Front, forward, backward or back, among the things its container or screen holds. |
| | Change Text, Duplicate, Delete, Hide or Show, Lock or Unlock, Rename, Select | A duplicate goes beside the original, in its container. |
| Canvas | **Change Canvas Settings** | Grid, grid style and spacing, snapping, frame names, spacing guides, background (named or hex), device for sketched screens (or **Custom Device for New Screens**), code layout, `#Preview`, navigation title, Magic Pen convert-after-pause and scratch-out. |
| | **Set Canvas View** | Zoom (%), centre `x`/`y` in canvas points, lock against touch. |
| | Zoom to Fit, Undo, Redo | |
| Ink | **Draw Strokes** | Strokes drawn with the Magic Pen (read into elements) or with a pen, monoline, marker or pencil (kept as ink). Returns the design afterwards. |
| | **Erase Ink** | Ink touching an area, or all of it. |
| | Convert Sketches, Clear Sketches | Read waiting Magic Pen sketches now, or throw them away. |

## Devices by name

Add Screen, Build Screen and Change Screen Device take a **Custom Device**, and Change Canvas Settings a **Custom Device for New Screens**: one of the design's own devices (made with Custom Size… in the device picker), by its name, ignoring case and the spaces round it. Given, it is used instead of Device. Shortcuts offers the names of the design at the front. Get Design Layout writes a screen's device as its id in `device` and as its name in `deviceName`; a built-in's name is the one Siri gives it, such as "Phone".

## Errors

Three errors came with the tree. Each says why nothing was changed:

- **`laidOut`**: "That element's place comes from the row, column or grid it's in. Change its order in the Layers panel, or move it out of the container first." Thrown by Move or Resize Element and Change Element Order for a child its container places.
- **`alignmentNotTaken`**: "That element is in a row, which aligns what it holds only to the top edge, vertical middle or bottom edge. Nothing was changed." Thrown by Align for an alignment along a row or column, which it has no use for; a screen's laid-out root is "its screen's column".
- **`deviceNotFound`**: "This design has no device called “Kiosk”. Make one with Custom Size… in the device picker." Thrown for a Custom Device the design doesn't have, or has but can't use, before anything is written.

A change that would take the design past 5,000 things, or 32 deep, says so and changes nothing.

## Voice

Voice mode (the call pill, and Squeeze to Talk) hands its model the canvas as a picture: each screen and what is on it, containers with what they hold indented under them, each with a handle such as `S1` or `E5`, its frame in screen points, its look, and `[locked]` for anything locked by itself or by a container above it. Its tools take those handles:

- **Screens:** `createScreen` (on a device of the design's own by its name too), `renameScreen`, `deleteScreen`, `tidyScreen`, `changeScreenDevice`.
- **Elements:** `addElement`, `setText`, `styleElement`, `moveElement` (with `takeOut` to take a row's, column's or grid's child out of it), `rotateElement`, `alignElement` (in a row, column, grid or overlay, by that container's alignment, as Siri's Align), `stackElements`, `placeElement`, `duplicateElement`, `deleteElement`.
- **Structure:** `groupElements` puts things in a new group, row, column, grid or card; `setLayout` changes how a container or a screen lays out what it holds (`free`, `row`, `column`, `grid of 2`, `overlay`, an alignment and a spacing); `ungroup` takes one apart, leaving what it held where it is; `reorder` puts a thing before or after another in the container they share. In a row, column or grid that is its place; elsewhere it is only which is in front.
- **The view:** `show`, `pan`, `zoom`, `undo`, `redo`, `endCall`.

The on-device model is handed every tool but `setLayout` and `reorder`, to keep within its context (docs/benchmarks/voice-on-device.md); a hosted model has all of them. A screen voice makes says, like Build Screen, what its generation couldn't put right. Each spoken command is one undo step.

## Generated screens

Generate and voice's `createScreen` have the design's model write the screen in Layer's outline, the format Build Screen reads. Every model writes the outline: hosted models did write A2UI until plan 6 measured both on LM Studio, where the outline was valid 24 times in 24 against A2UI's 13, and came sooner (docs/benchmarks/screen-prompt.md). Layer still reads A2UI wherever it is given: Build Screen, paste and import.

## Build Screen's layout

**Build Screen** reads its layout as an outline, one element per line from top to bottom, written `kind: words [look]`:

- **Containers.** A line `card:`, `column:`, `row:` or `grid 2:` (any number of columns from 1 to 12) holds the lines indented under it, two spaces a step. `row: a | b` puts elements side by side on one line.
- **Sections.** A blank line or `---` starts a new section. A container written straight after a section's lines, with no blank line between, joins that section.
- **A2UI.** A layout that starts with `{` or `[` is read as A2UI 1.0 JSON instead, and Layer builds its components.

Rebuilding a screen keeps what was built before where it is, and leaves what was added by hand alone.

```
title: Create account
text field: Email
text field: Password
row: checkbox [off] | text: Remember me [left]
progress [40%]
button: Sign up [blue, bold]
button: I have an account [plain]

card:
  text: Already a member?
  row:
    text: Sign in instead
    button: Sign in [bordered]
```

Kinds: title, body, button, text field, image, symbol (`symbol: heart.fill`), divider, toggle, checkbox, radio, progress, avatar, text.

## Look words

**Build Screen**'s square brackets, and the **Look** parameter of Add Element and Style Element, take comma-separated words:

| Words | Sets |
|---|---|
| `blue`, `#0A84FF` | Fill colour |
| `text white`, `text #333333` | Text colour |
| `regular`, `medium`, `semibold`, `bold` | Font weight |
| `fill`, `fit` | Width in Build Screen: stretch across, or keep the usual size |
| `on`, `off`, `checked`, `unchecked`, `selected` | Toggles, checkboxes, radio buttons |
| `40%` | How full a progress bar is |
| `filled`, `bordered`, `plain` | Button style |
| `left`, `centre`, `right` | Text alignment |
| `shadow`, `no shadow` | Shadow |
| `border red` | Outline colour |

These numbers apply to Add Element's and Style Element's **Look** only. Build Screen passes them over, and each kind keeps its own size, corner and outline, as a generated screen does:

| Words | Sets |
|---|---|
| `18pt` | Font size |
| `radius 12` | Corner radius |
| `border 2` | Outline width |
| `opacity 50%` | Opacity |

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
- Selecting several things at once. Each action works on one element or one screen. (Voice's tools take several.)
- Containers by themselves. Siri sees elements; a container is made, laid out and taken apart in the canvas, the Layers panel, Build Screen or voice.
