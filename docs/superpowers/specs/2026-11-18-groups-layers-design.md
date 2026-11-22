# Groups, layer order, the Layers panel, and tap-to-add selection: design

Date: 2026-11-18. Status: approved by the user on 2026-11-18. Branch: `feature/groups` (worktree
`.claude/worktrees/groups`), started from `feature/rotation` and rebased onto it once rotation
is finished, because a group turns the way several things do.

Background research: `reports/Rotation grouping selection and zoom.md` and its notes in
`research_notes/Rotation grouping selection and zoom/` (in the main checkout, not committed),
especially `grouping_and_layers.md`, `touch_multi_selection.md`, and the code audit
`layer_codebase_audit.md` §1.2, §2, §4.3, §5, §10.2–10.3. Rotation's design:
`docs/superpowers/specs/2026-11-18-rotation-design.md`.

## Intent

The second piece of the round of editing tools the user asked for on 2026-11-18: "proper
element groupings, proper layering and groupings in the layout section" (the Layers panel),
and, for touch, "select an element, then select another and another to group/lock/edit/delete
etc them altogether … only deselect all if canvas was touched. if element is part of the
selected and got selected again then it may be deselected." Layer is an iPad app where the
Apple Pencil draws and a finger selects and edits. Today a tap replaces the selection (adding
needs a second finger resting on the canvas), there are no groups, only forward/backward
exist as buttons, and the Layers panel lists things but can't change their order.

## Goals

1. **Tap-to-add.** A finger tap on a thing adds it to the selection; a tap on something already
   selected takes it out; only a tap on empty canvas clears the selection. Then the selection
   is grouped, locked, edited, arranged or deleted together.
2. **Groups.** Several things become one group (Group), and a group goes back to its members
   (Ungroup). A group is selected, moved, turned, resized, locked, hidden, named, duplicated,
   arranged and deleted as one thing. Groups nest.
3. **Getting inside a group.** A tap on a grouped thing selects its outermost group; a
   double-tap goes one level in, down to the thing itself. The Layers panel reaches any level
   directly.
4. **Layer order.** Bring to Front, Bring Forward, Send Backward and Send to Back, for one
   thing, a group, or several things at once (moved as one block, keeping their own order).
5. **The Layers panel shows and edits order and groups.** Each screen (and the open canvas)
   lists its things topmost first; a group is a row with a disclosure arrow and its members
   indented beneath it; rows are dragged to change the order, into a group, and out of it.
6. **One undo step** for each group, ungroup, arrange, panel drag, and change made from a button
   or toggle. Selecting itself isn't undone, as today.

## Non-goals

- Drawings in layer order or in groups (see "Decided by the user").
- Groups spanning screens, or holding screens.
- Groups in the generated code (members export as they do today), in voice commands, and in
  Siri / App Intents. Voice and Siri must keep working with grouped elements; they just don't
  know about groups yet.
- Frames/containers with clipping or layout (a screen is already that), and Figma-style
  sections.
- Hand-drawn reordering by dragging on the canvas itself (a Keynote-style layering slider).
- Fractional order keys for iCloud merging; order stays array position.

## Anti-goals

- **A tap that silently loses the selection.** Building a selection of three things must not be
  undone by a tap that only just misses one of them.
- **Single taps that feel slow.** Telling a tap from a double-tap must not delay every tap.
- **Groups that rot.** No group of one, no empty group, no group whose members are scattered
  through the order with other things between them.
- **Drag handles that fight scrolling.** The Layers panel must still scroll with a finger.
- **Losing work in older builds beyond grouping.** A design with groups opened in an older Layer
  build must still open with every element in place.
- **Controls moved around the palette** (agreed 2026-11-16).

## Constraints

Facts from the code (main d5274ef plus rotation) and the platform:

- **One list.** `DesignContent.elements` (`Layer/Document/DesignFile.swift`) holds every
  element, back to front; each has `parent` (a screen, or nil for the open canvas). Order
  only means something among elements with the same parent. `screens` and `floating` are
  views of the list, and the `screens` setter rebuilds the list from them. Elements a build
  can't read are kept in `unread` and written back.
- **Selection.** `CanvasSelection` (`.element`, `.screen`, `.several(Set)`) is transient; an
  element whose screen is also selected is folded into the screen. `AppModel.pick(_:)` replaces
  the selection unless a finger rests on the canvas (`RestingFingerDetector`), when it toggles.
  A box after a 0.4 s rest and the palette's lasso replace the selection
  (`AppModel.select(enclosedBy:)`, `boxDragged`). Element taps come from SwiftUI targets in
  `SelectionLayer`/`ElementTargets` (`.onTapGesture { model.pick(...) }`); canvas taps from
  `InkCanvas`'s tap recogniser into `AppModel.canvasTapped(at:)`, which picks the screen under
  the point or nothing. Dragging an unselected element selects it alone
  (`CanvasDrags.adjust`). Two tests assert replace-on-tap and change meaning:
  `aTapWithNoFingerRestingSelectsOnlyWhatIsTapped` and
  `aFingerRestingOnAPanelIsNotRestingOnTheCanvas` (`LayerTests/MultiSelectionTests.swift`).
- **Order.** `DesignStore.Arrangement` (front/forward/backward/back), `arrange`, `canArrange`,
  `siblings(of:)` and `DesignContent.reorder` work and are tested for one element; Siri has all
  four (`ArrangeElementIntent`). Only forward/backward have buttons (`SelectionActions`,
  `StylePanel`), only for one element (⌘] / ⌘[).
- **Ink.** Unlocked drawings are on one PencilKit canvas drawn above every element; drawings
  and sticky notes live on the open canvas (`belongsOnScreens` false).
- **Several things.** `SeveralThings.swift` moves, aligns, distributes, duplicates, deletes,
  locks and rehosts a multi-selection; with several selected there are no resize handles.
  Rotation adds `TurnSession` (turning several things about a fixed pivot) and a turn API on
  `AppModel`.
- **Layers panel.** `Layer/Chrome/LayersPanel.swift`: screen header rows, then
  `ForEach(screen.elements.reversed())` rows (topmost first) with lock/hide toggles and Pencil
  hover linking to the canvas; a "Canvas" header for floating things. No drag, no nesting.
- **Reordering API.** The installed SDK (iPhoneSimulator 27.2) has `reorderable()`,
  `reorderable(collectionID:)` and `reorderContainer(for:in:move:)` delivering a
  `ReorderDifference`; it reorders within and between flat collections, with no built-in
  "drop onto a row to nest". A throwaway spike (`spike/layers-reorder`, findings in its
  `SPIKE-FINDINGS.md`) tested it: see "Spike result" below.
- **Kinds.** `ElementKind` is a `String` enum with a catalogue spec per kind
  (`Layer/Components/Catalogue.swift`), a golden of every kind's answers
  (`LayerTests/Goldens/ComponentKinds.txt`), and about a dozen `switch`es over it (rendering,
  code generation, voice, intents).
- **Testing limits.** XCUITest can tap, double-tap and do straight press-and-drags; it can't
  rest one finger while tapping with another, and can't make Pencil input. The user's iPad mini
  is the device for real touch feel (currently in use by another session).

## Approaches

### How a group is stored

- **A. A group is its own item in the one list (chosen by the user).** A new kind, `.group`,
  sits in `DesignContent.elements` like everything else. It carries the group's name, lock,
  hide and angle. Each member points at its group with a new optional field; members stay on
  their screen (`parent` unchanged). The group's box is worked out from its members. Groups
  nest by a group pointing at an outer group. Undo, duplicate, delete, lock, hide, naming and
  file saving come from what already works for every element. (tldraw's model.)
- **B. Group tags on each element** (Excalidraw's model). Quicker to add, but a group's name,
  lock and hide need a separate table that can drift, and nothing keeps members together in
  the order. Rejected.
- **C. A real tree** (screens and groups holding child arrays). The cleanest structure, but a
  rewrite of the one-list model merged on 2026-11-18. Rejected.

### How the Layers panel drags

- **A. SwiftUI's iPadOS 27 reordering (chosen by the user), tried in a spike first.** Rows of
  each list are `reorderable`; dragging between lists moves into or out of a group; dropping on
  a collapsed group's row, if the spike shows it can coexist, puts the row inside.
- **B. A UIKit collection-view list** with diffable outline sections: mature nested
  drag-and-drop, but a different technology inside a SwiftUI panel. The fallback if the spike
  fails.
- **C. No dragging**, only buttons. Rejected: not "proper layering in the layout section".

## Decided by the user

- Drawings stay on top (2026-11-18, "drawings are option 1 stays on top"): unlocked ink keeps
  drawing above every element. Layer order covers everything else; the Layers panel shows
  drawings in a section of their own, not draggable among elements.
- My proposals they saw and accepted ("drawings and layering lgtm"):
  - With something selected, a tap on a screen's empty area clears the selection (as the
    canvas does); with nothing selected it selects the screen, as today. A tap on a screen's
    name label adds the screen to the selection.
  - Getting inside a group is a double-tap, or a row in the Layers panel, because tapping a
    selected thing again takes it out.
- Approaches: A for storage, A for the panel ("sounds good lets do A", "and A").
- Seen and not corrected: a group stays on one screen or on the open canvas; resizing a
  group scales its members' positions and sizes but not their text; groups don't change the
  generated code this round; groups build on rotation.

## My calls (correct any of them)

### Tap-to-add

- **A tap on a thing** (element, group, or a screen's name label), by finger, or by the
  Pencil with Draw off: with nothing selected, selects it; otherwise adds it, or takes it out
  if it is selected. One `UISelectionFeedbackGenerator`-style tick per add or remove.
- **A tap on empty canvas** clears. **A tap on a screen's empty area** clears when something is
  selected, and selects the screen when nothing is.
- **A near miss does nothing.** A tap that hits no thing but lands within 8 pt (on the glass) of
  a selected thing's outline is ignored, rather than clearing the selection. A group is hit
  anywhere inside its box, so a tap in the gap between an icon and its label picks the group.
- **A tap on something inside a selected screen or group** replaces that screen or group with
  the tapped thing (the same as going one level in). Adding a screen or group whose contents are
  selected folds them into it, as today.
- **A double-tap** never waits: the first tap acts at once, and a second tap on the same thing
  within the system double-tap interval is read against the selection as it was **before** the
  first tap. If the thing's outermost group (or the screen or group holding it) was selected
  then, the double-tap goes one level in from there. If the thing is in a group that wasn't
  selected, it selects that group and goes one level in. If it's an ungrouped thing, it ends up
  selected (a double-tap never takes a thing out).
- **Dragging** a thing that isn't selected moves it alone and makes it the selection (as
  today); dragging a selected thing moves the whole selection (as today). For a grouped
  element, "the thing" is its outermost group, the same as a tap picks: a drag on an unselected
  member moves the whole group. A member moves on its own only once it is selected inside the
  group (double-tap or the Layers panel).
- **The box after a rest, and the lasso,** still replace the selection.
- **A finger resting while another taps** still works; it is now the same as tapping.
- **Rows in the Layers panel** follow the same rule as the canvas: a tap adds or takes out.
- **Text editing** still starts from the popover's button.

### Groups

- **Group** (popover button, format panel, ⌥⌘G) needs two or more things on one screen or on
  the open canvas. Locked things and drawings are left out of the new group; if fewer than two
  remain, Group is disabled. A selection spanning screens can't be grouped (Group disabled,
  with the reason as its accessibility hint).
- **The new group** goes where the topmost member was in the order; its members gather into one
  block just behind it, keeping their order. It is named "Group" (shown as the kind's name until
  renamed) and selected.
- **Ungroup** (popover, format panel, ⌥⇧⌘G): the members move up to the group's own group (or
  none) and keep their places in the order; the members become the selection. Not recursive.
- **A group of one dissolves; an empty group goes.** Checked after every change (delete, move
  out of the group, undo).
- **Selecting:** a tap on a member selects its outermost group (on the same host). A
  double-tap goes one level in: the selected group is replaced by the member's group one level
  down, or by the thing itself. While a member is selected, taps on its siblings add them; a tap
  on anything outside adds that thing's outermost group. The lasso and the box pick whole
  outermost groups (by the group's box, the same share rule as elements), never members alone.
- **The group's box** is the box round its members at the group's own angle (0 until it is
  turned); it is kept on the group item's `frame` and `rotation` so every reader of a box sees
  it.
- **Moving** a group moves its members; dropped with its middle on another screen, the whole
  group moves there (members keep their places relative to each other). A member dragged on
  its own to another screen leaves the group.
- **Turning** a group turns its members as one piece about the group's centre (rotation's
  `TurnSession`); the group's angle becomes the outline's angle.
- **Resizing** a group scales its members' frames from the opposite corner, keeping the box's
  proportions (so turned members never shear); text sizes don't change. A group has its four
  handles and its rotation knob.
- **Lock and hide:** a group's own flags; a member is effectively locked or hidden when it or
  any group above it is. Members keep their own flags. A locked group can be selected and gone
  into, but nothing in it moves. A member locked on its own can't be moved, resized or turned
  by itself, but it goes with its group when the whole group is moved, turned, resized or
  deleted (as in Figma): a group is one thing. When a group is ungrouped or dissolves, its lock
  and hide pass down to its members, so a hidden group's members don't reappear.
- **Duplicate** copies the group and its members (new ids, members pointing at the copy).
  **Delete** deletes the group and its members.
- **Format panel** for a group: its name, the actions row (Duplicate, Lock, the four arrange
  commands, Ungroup), its box's X/Y/W/H (moving and resizing the members), Rotation, and the
  settings the several-things panel shows today, applied to every member that has them.
- **Popover** for a group: Ungroup beside Duplicate, Lock, Arrange and Delete; for several
  things: Group.
- **Older builds** keep a group item as an element they can't read (written back unchanged).
  From 0.2.0 (4) on they also write members' pointers back, so saving there keeps the grouping,
  which comes back here; a member they duplicate keeps the pointer and joins the group, and one
  they move to another screen leaves it. Builds up to 0.2.0 (3) drop the pointers when they
  save, so grouping is lost there and nothing else is. (Ruling A, 2026-11-22.)

### Layer order

- **Commands:** Bring to Front (⇧⌘]), Bring Forward (⌘]), Send Backward (⌘[), Send to Back (⇧⌘[)
  — the Keynote/Pages shortcuts. The popover gets one Arrange button opening a menu of the four;
  the format panel's actions row shows all four.
- **What moves:** a thing or a group moves among its siblings: the things on the same screen (or
  the open canvas) inside the same group (or at the top level). A group moves as its whole block.
  Several things move as one block keeping their own order (tldraw / Motion). Several things on
  different screens each move within their own screen.
- **Forward/backward step past one sibling** (a whole group counts as one), not past
  non-overlapping things; simple and predictable in the panel.

### The Layers panel

- **Rows:** each screen's header, then its top-level things topmost first; a group row has a
  disclosure arrow, a group symbol, its name, and the lock and hide toggles; its members are
  indented beneath it. A group is shown open while something inside it is selected, otherwise as
  last left. The open canvas's section lists floating things the same way, with a "Drawings"
  section of its own at the top. Locked drawings, which today are drawn among the floating
  things at their place in the order, are drawn above the other floating things instead, so
  every drawing is on top as the user decided and the panel tells the truth.
- **Dragging** a row (touch and hold, then drag) moves it within its list, into an open group's
  list, or out of a group to the list above. A row can't be dragged to another screen's list
  (it springs back). Drawings' rows don't drag. Dropping onto a closed group's row puts it inside,
  at the top (see "Spike result").
- **Hover:** Pencil hover over a group row outlines the group's box on the canvas, as rows do
  today.
- **VoiceOver:** rows get "Move Up", "Move Down", "Move Into Group Above" and "Move Out of Group"
  custom actions, so order and grouping can be changed without dragging.

## Edge cases

| Case | Behaviour |
|---|---|
| Tap A, B, C (nothing selected first) | A, then A+B, then A+B+C selected. |
| Tap B again | A+C selected. |
| Tap empty canvas | Nothing selected. |
| Zoomed into a screen, A+B selected, tap the screen's empty area | Nothing selected. |
| Nothing selected, tap a screen's empty area | The screen is selected. |
| A+B selected, tap the screen's name label | The screen is added; A and B, being on it, fold into it (as today). |
| Quick double-tap on an ungrouped element | It is selected (a double-tap never takes a thing out). |
| A screen is selected; tap an element on it | The element replaces the screen in the selection. |
| A+B selected; tap 4 pt outside A's outline | Nothing changes (a near miss). |
| Group G selected; double-tap one of its members | G is replaced by that member (or its group one level down). |
| Drag a member of an unselected group | The whole group moves. |
| A member locked on its own; move its group | It moves with the group. |
| Ungroup a hidden group | Its members stay hidden. |
| Tap a member of a group | The group is selected. |
| Double-tap a member of a nested group | First the outer group, then one level in per double-tap. |
| Member selected; tap empty canvas | Nothing selected. |
| Group a selection with a locked element and two others | The two unlocked ones are grouped. |
| Group a selection spanning two screens | Group is disabled. |
| Delete one member of a two-member group | The group dissolves; the other member stays where it was in the order. |
| Undo after grouping | One step: the group is gone and the members are back in their old order. |
| Bring Forward on a group | The whole block moves past the sibling in front of it. |
| Send to Back on A and C with B between them | A and C move to the back as a block, A behind C. |
| Drag a row out of a group in the panel | It leaves the group and sits where it was dropped; a group left with one member dissolves. |
| Drag a row onto another screen's list | It springs back. |
| Hide a group | Its members aren't drawn and can't be tapped; its row and members' rows are dimmed. |
| Turn a group, then ungroup | Members keep their turned positions and angles. |
| Resize a group holding a turned member | The member scales uniformly with the box; no shear. |
| Open a design with groups in an older build | Everything opens in place, ungrouped there. Saving in 0.2.0 (4) or later keeps the grouping, which comes back here (a member duplicated there joins the group); 0.2.0 (3) and earlier drop it. |
| Voice "make the title blue" when the title is grouped | Works as today: voice sees elements, not groups. |

## Spike result

From the throwaway spike on `spike/layers-reorder` (commit 3164a9c, `SPIKE-FINDINGS.md`): a
harness with the Layers panel's structure (`ScrollView` > `VStack`, button rows with toggles, not
a `List`) on the iPad Pro 11 simulator, iOS 27.2, driven by XCUITest.

- **Reordering within a list works.** `ForEach(…).reorderable(collectionID:)` with
  `.reorderContainer(for:in:)` on an ancestor. Touch-and-hold then drag starts it; a plain tap
  still selects; the lock toggle still works; a quick swipe scrolls instead of dragging.
- **Moving between lists works** and lands between specific rows: the callback gives the
  dragged ids, the destination list and `.before(id)` or `.end`. The model change is ours to
  make. The panel shows topmost first, so "before" a row on screen is "after" it in the list.
- **A drop on a group's header row works only with extra wiring:** `.dragContainer` with a
  `Transferable` payload must be attached as well as `.dropDestination` on the header. Then the
  header drop fires and the reorder doesn't, and ordinary reordering keeps working. Without it,
  the header silently ignores drops.
- **Not tested:** the real panel, a real finger and the system's hold threshold, VoiceOver move
  actions, auto-scroll at the edges, a header that is itself a reorderable row.

So the panel uses SwiftUI's reordering (no UIKit list): each screen's (and the open canvas's)
top-level list and each open group's member list is a collection; dropping between rows of
another collection moves into or out of a group; and a closed group's row takes a drop through
`dragContainer` + `dropDestination`, putting the row inside at the top. VoiceOver gets the
custom move actions above whatever `reorderable` provides. The builder checks the untested items
on the real panel first, and falls back to "a closed group opens while a row hovers over it" if
the header drop proves unreliable.

## Left to the builder

- The exact shape of the model change: the member pointer's name, how `.group` joins the
  catalogue (no Magic Pen reading, no fill, no code), and keeping group items out of the views
  that draw, export, describe and hit-test elements (`DesignScreen.elements`, `floating`)
  without the `screens` setter dropping them.
- One place that keeps groups healthy after every change (box and angle kept current, groups of
  one dissolved, empty groups removed, blocks kept together), and how often it runs.
- How "goes one level in" is tracked between taps, and how a double-tap is recognised without
  delaying single taps.
- The panel's row view structure and how open/closed state is kept (per session, not saved).
- Tests: unit tests for tap-to-add (A, B, C, again, canvas, screen background, label), group and
  ungroup (block placement, locked and drawings left out, spanning screens refused), dissolving,
  selecting into groups, lasso picking whole groups, arranging one, a group and several
  (block rule), duplicate/delete/lock/hide of groups, resize scaling, turning a group, the
  file round-trip and an older-build round-trip (unknown kind kept, members' pointer dropped),
  and that code, voice description and Siri entities skip group items; UI tests for tap-to-add,
  Group/Ungroup from the popover, a double-tap into a group, and a panel drag; a device checklist
  for the feel of tap-to-add, the double-tap, and panel dragging.
