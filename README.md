# Layer

Sketch a phone screen with Apple Pencil and Layer turns it into a real design, then into SwiftUI code.

Layer is a freeform canvas for iPad. Draw a tall rectangle and it becomes an iPhone frame. A zigzag at the top becomes a title. A box with a cross becomes an image, stacked lines become body text, and a rounded bar becomes a button. Everything stays editable, and every screen has its SwiftUI source a tap away.

![Sketching with the Magic Pen: a box with a cross is being read as an image](docs/screenshots/sketching.jpg)

## Features

- **Magic Pen.** A pen in the PencilKit palette whose strokes are read as interface elements. The full palette (pens, eraser, lasso, ruler) is there too and draws ordinary ink.
- **Apple Intelligence first.** Built-in shape rules settle clear sketches instantly. On the close calls, such as a rounded box that could be a button or a text field, the on-device model decides from what else is on the screen. Without Apple Intelligence the rules decide everything, so Layer works on any iPad.
- **A real canvas.** Pinch to zoom, pan, lock the canvas, zoom to fit. Frames, elements and drawings can be selected, moved and resized, with snapping and spacing guides.
- **Add things directly.** Text, device frames (iPhone, iPhone Pro Max, iPhone SE, iPad), sticky notes, SF Symbols and images.
- **Freeform-style objects.** A bar above the selection duplicates, locks and reorders it (⌘D, ⌘L, ⌘], ⌘[). Dragged things snap to smart guides or the grid. Layers can be named, hidden and locked. A selected drawing gets a prompt instead: type what it should be ("a button saying Sign up"), or just tap the sparkle and let the model decide.
- **Format panel.** Position, size, fill, border, shadow, corner radius, opacity, alignment and type for the selection, plus arranging and aligning it on its screen.
- **Board menu.** Tap the board's name to rename it. Tabs below hold the canvas, Magic Pen and code settings, and converting or discarding a Magic Pen sketch by hand; the icon in the name field shows where the file stands with iCloud.
- **More Magic Pen shapes.** A small pill becomes a toggle, on or off by which end its knob is drawn at, and a small circle an avatar. A tiny square becomes a checkbox (ticked if you draw a tick or an X in it), a tiny circle a radio button (selected by a dot), and a long, thin box a progress bar filled as far as you shade it. Beside the screens, a box becomes a sticky note and a squiggle becomes text. Scratching back and forth over an element deletes it.
- **Tidy sketched layout.** A box drawn half the screen wide becomes one of two columns, so two buttons side by side stay side by side, and the second button on a screen is outlined. Text drawn against the leading edge is leading-aligned, a title's size follows how tall it was drawn, text beside a checkbox starts after it, and gaps to the element above snap to 8, 12, 16, 24 or 32 points. In the code, elements side by side become an `HStack`.
- **SwiftUI code.** The Layers panel's Code tab shows each screen as SwiftUI, ready to copy or share. The code can be a stack or use exact positions, end with a `#Preview`, and use the title as a navigation title. Every screen can be shared as files at once.
- **Automation.** Everything on the canvas can also be done through Siri and Shortcuts actions: adding and styling every kind of element, building whole screens from a description, moving screens and elements, canvas settings and view, reading the layout back as JSON, and drawing strokes with the Magic Pen or ordinary pens. See [docs/automation.md](docs/automation.md).
- **Documents and iCloud.** Designs are documents in Files and iCloud Drive. A design's file is named after its board, the document browser shows a thumbnail of each board, and versions edited on two devices at once are both kept.
- **Any window size.** In a narrow window the tools fold into a menu, the panels become sheets and the palette can be tucked away.

![The Format panel for a selected button](docs/screenshots/format-panel.jpg)

![The generated SwiftUI for a screen](docs/screenshots/code-panel.jpg)

## Requirements

- iPadOS 27 or later
- Xcode 27.2 or later to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Intelligence is optional

## Building

The Xcode project is generated from `project.yml`, so regenerate it after adding or removing files:

```sh
xcodegen generate
open Layer.xcodeproj
```

Run the tests in a simulator:

```sh
xcodebuild -project Layer.xcodeproj -scheme Layer \
  -destination "platform=iOS Simulator,name=<an iPad simulator>" test
```

The UI tests expect a landscape iPad simulator with the app's window full screen.

There are two test plans. `Layer` (the default) runs everything. `CI` runs the unit tests
only and skips `SiriIntentsLiveTests`, which drives the document browser and is flaky on
fresh simulators. Choose it with `-testPlan CI`.

## TestFlight

Xcode Cloud builds every push to `main`, archives it and sends it to TestFlight internal
testers. `ci_scripts/ci_post_xcodebuild.sh` fills in each build's "What to Test" notes from
the latest commit messages. Xcode Cloud sets the build number itself.

App Intent titles, descriptions and enum names must not contain Apple trademarks
(Siri, iPhone, iPad, Apple). App Store Connect rejects the upload with ITMS-90626.

## Project layout

| Folder | What's in it |
| --- | --- |
| `Layer/App` | The app, its document scene and the per-design model |
| `Layer/Canvas` | The canvas: PencilKit ink, screens, selection, effects |
| `Layer/Chrome` | Top bar, panels, zoom and undo controls, share menu |
| `Layer/Sketch` | Reading sketches: shape analysis, rules, Apple Intelligence |
| `Layer/Model` | Screens, elements, layout and the design store with undo |
| `Layer/Document` | The `.layer` package format, file naming and iCloud |
| `Layer/Code` | The SwiftUI code generator and its syntax colouring |
| `LayerThumbnails` | Quick Look extension that draws thumbnails for Files |
| `LayerTests`, `LayerUITests` | Unit tests and end-to-end UI tests |

## Adding another model provider

Apple Intelligence is the built-in provider. To add a hosted model, write a type that conforms to `SketchInterpreter` in `Layer/Sketch/SketchInterpreter.swift` and add it to `SketchProvider.all`. Providers that need an API key set `needsAPIKey`, and the key is passed to `makeInterpreter`.
