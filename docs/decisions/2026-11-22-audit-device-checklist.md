# Device checklist: iPad mini, Apple Pencil Pro (audit 2026-11-22)
Install from main (525477c, version 0.2.0 build 4). Format: action → expected result. "(priority)" marks the 8 to do first. Record results next to each line.

## Rotation
- (priority) Twist a selected button with two fingers → it turns and keeps its size.
- (priority) Start dragging an element, then add a second finger and twist → one Undo ("Move and Rotate") takes back both; the next one-finger drag works; the element lands on the screen it lies over.
- (priority) Turn with the knob and with a twist across 0/45/90 → a tick at each; no tick when you only grab the knob of an upright element; thresholds (±4°, 8° of turn before 8% spread) feel right, else tune.
- Drag a sticky note made at another screen's scale over a screen, then twist → its drawn size does not jump badly (if it does, land at the end of the turn instead).
- Pinch with two fingers starting anywhere, including on the selection → the canvas zooms and nothing turns.
- Put two fingers half on and half off the selection → it behaves as it did before rotation.
- Scroll with two fingers far apart (about 300 pt) starting on the selection → the canvas pans after at most about 36 pt, without a visible jump.
- Twist with Lock Canvas on → the selection still turns.
- Squeeze over the Rotation field and roll the barrel → one degree per degree, ticks every 15°, the ruler shows; squeeze again keeps the value.
- Zoom to 25% and to 400% → the knob is reachable at both.
- Erase part of a turned drawing, then draw a stroke that joins it → the rest stays exactly where it was.
- Hold the knob with one finger, tap the Pencil on the element, lift → the popover returns and the next change is its own undo step.
- In a narrow window, put two fingers on the Format sheet over the selection → the selection does not turn.
- Turn several things, then double-tap the knob; also use VoiceOver "Rotate 15°" and "Reset rotation" → they return together; reset on a fresh selection stands each upright.
- Say "rotate the button 45 degrees", then "straighten it" → it turns, then stands upright.
- Say "tidy this screen" and "make it an iPad" with a turned button on it → it keeps its angle and size, nothing overlaps it, it stays on screen.
- Zoom to Fit, then look at the board thumbnail and share picture with a turned element at the edge → the whole turned shape is in view.

## Undo and concurrent edits
- (priority) Hold an element while a screen finishes writing, drop it on that screen, press Undo → the element stays visible (not lost); a second Undo puts it back where it began.
- Rub with the eraser while a screen is being written, then Undo twice → the drawing returns to how it was, never half erased.
- Say "No, that's wrong." after you moved by hand what the command changed → your move stays; the app says it did not undo.
- Say "undo" right after a hand edit → it acts like the Undo button and takes back your edit.
- Draw strokes while a screen is written, then press the palette's Undo once → check what goes (the whole screen may go; Redo brings it back), and count the presses.
- Drag an element from screen A onto B and press Undo once → it is back on A at its old spot (one step).
- Cut a drag short (Pencil lands on it, or change tool) over another screen → it lands there once, keeps its stacking order, one Undo.
- Change a fill for several things, tap Duplicate within 0.6 s → Undo takes back the copies, then the fill separately.
- Open the Undo menu after a drag, resize, turn, format change, typing, erase, generation and voice command → each names its action.
- Write a word with Magic Pen so it converts → one Undo removes the element and its words.
- Start a pen stroke, flick the bar or start a call before lifting, then edit → each later change is still its own undo step.
- Keep drawing with the Magic Pen across a conversion landing → no stroke is dropped or split.

## Voice and Pencil push-to-talk
- Say two-tool commands ("make the title bold and duplicate it", 20 times) → both happen in the order said; log `onToolCall` order against the answer's order.
- Say "No border on the button", then "No, make it red" → the first is a command; the second undoes the last command and then acts.
- Start voice mode, invoke Siri, then end Siri → look for "microphone: interrupted"; the call must not sit in "listening" with a flat waveform.
- Plug in a headset during a call → note whether it ends (known, unfixed) and what it says.
- Settings, Developer, Reset Media Services during a call → note what the call does.
- Say "make the title red" on a screen with more than 80 text elements → it works or fails with a clear message.
- Squeeze many times very briefly → "route: recogniser listening" never appears after "stopped"; memory stays flat.
- Squeeze, release, press Home at once, return → the next squeeze hears.
- Stop a hosted-model command mid-answer (needs a key) → it shows "Stopped", not "done".
- With Pencil in hand in Draw, tap a finger-selected element → it deselects and is not selected again.

## Canvas, palette and keyboard
- (priority) In Draw, type in a text popover or a drawing's prompt, then close it → the palette comes back; the keyboard does not drop while a sketch converts mid-typing.
- In Select, rename a layer, dismiss the keyboard, then ⌘Z or a three-finger swipe → Undo reaches the design.
- Tap and drag on ink drawn over a button in Select → the drawing is picked and moved; circle a 44 pt button and tap its edge → judge the 14 pt tolerance.
- Hide an element, then tap and hover over it with Pencil and finger → it is never picked or outlined.
- Zoom to Fit, then pan within 0.3 s → the glide stops, shadows stay, text stays sharp; toggle Lock Canvas mid-pinch → same.
- Type 100 in X, tap Align left, press Return; also Undo while the field is focused → the alignment and the Undo stand.
- Roll the barrel while the Pencil is out of hover, then bring it back → the value does not jump; a finger on another field scrubs that field only.
- Hold the Pencil still after changing selection, then squeeze → the new selection's field scrubs, not the old one.
- Hover a Layers row, close the panel with a finger, hover the canvas → no outline sticks.
- Type "12.5" in a comma-decimal region → it reads 12.5, not 125.
- Write two sketches quickly with the real handwriting reader → each gets its own words.

## Documents, iCloud, Siri and Spotlight
- (priority) Launch with an evicted iCloud design → Files shows no download; its screens stay in Spotlight; its placeholder is listed by name.
- (priority) Open design A, draw, then within 2 s ask Siri to open B → B opens; A's Quick Look thumbnail shows the last edit; two Siri opens in a row both work.
- Open a large evicted design through Siri → it opens once and is not dismissed twice.
- Change only a suggested title, press Back, reopen; also background the app, kill it from Xcode, reopen → the title is kept.
- Edit a design on a newer build, then here, then save → its pictures, ink and unknown keys survive.
- Edit one design offline on two devices, then reconnect → the other version is kept as a copy; unsaved work is not lost.
- Open one design in two Stage Manager windows and edit both → note which edit wins.
- Delete the open design in Files on another device → note whether autosave recreates it.
- Run a Siri edit, change other things, ask Siri to undo → only the action's changes go; a notice shows when nothing is left; log the thread.
- Rename the file in Files, then ask Siri for the design by its old name → it still opens; an untitled board shows the file's name.
- Search Spotlight for a screen name after launch → found; Share Design File → the copy has the latest edit.

## Performance feel
- Drag an element on a busy board (40 elements, drawings) with Layers and Code tabs open → smooth at 120 Hz; Copy gives the latest code.
- Turn a drawing with the knob, and pinch a busy board → ink follows without lag; shadows return when the pinch settles.
- Add a 48 MP photo, share a big board, tap Back on one → no visible stall; Time Profiler at cold launch.
- Draw five ambiguous outlines and pause → no "CancellationError" in the sketch log; time the first handwriting read on a fresh install and the first Apple Intelligence check after boot.
