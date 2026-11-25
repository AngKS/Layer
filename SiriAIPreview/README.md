# Siri AI Developer Preview: staged, not built

Layer's App Intents in `Layer/Intents/` ship with the iOS 26.6 deployment target and work today in Shortcuts, Spotlight, App Shortcuts and Siri phrases. Everything in this folder needs the **Siri AI Developer Preview**, which the installed Xcode 27.2 SDK doesn't include. It has no `.tool` trait, `ToolIntent`, `GenerableEntity`, `@AppEntity(.generable)`, card snippets, `description:` on entity properties, or Skills Bundle template. None of this folder is in a target, and none of it has been compiled.

## Once a preview SDK is installed

1. **Promote the intents to tools.** Add `@AppIntent(.tool)` to these intents in `Layer/Intents/`. First try it on a type that stays available from iOS 26.6; if the compiler demands iOS 27 for the whole type, add a thin `@available(iOS 27, *)` tool per action that calls the same `DesignActions` code and sets `isDiscoverable = false`.
   - Designs: `CreateDesignIntent`, `RenameDesignIntent`, `DescribeDesignIntent`, `GetDesignLayoutIntent`, `ExportDesignImageIntent`, `GenerateSwiftUICodeIntent`, `FindDesignsIntent`
   - Screens: `AddScreenIntent`, `BuildScreenIntent`, `RenameScreenIntent`, `ChangeScreenDeviceIntent`, `MoveScreenIntent`, `SetScreenLockedIntent`, `DuplicateScreenIntent`, `DeleteScreenIntent`, `FindScreensIntent`
   - Elements: `AddElementIntent`, `AddImageFileIntent`, `EditElementTextIntent`, `StyleElementIntent`, `MoveElementIntent`, `MoveElementToScreenIntent`, `AlignElementIntent`, `ArrangeElementIntent`, `DuplicateElementIntent`, `DeleteElementIntent`, `SetElementHiddenIntent`, `SetElementLockedIntent`, `RenameElementIntent`, `SelectElementIntent`, `FindElementsIntent`
   - Canvas, ink and history: `UpdateCanvasSettingsIntent`, `SetCanvasViewIntent`, `DrawStrokesIntent`, `EraseInkIntent`, `UndoIntent`, `RedoIntent`, `ConvertSketchesIntent`
   - Leave `OpenDesignIntent` and `OpenScreenIntent` alone: on iOS 27 give them `@AppIntent(schema: .system.open)` instead, which Siri already supports. Adding `.tool` to a Siri-supported schema is a build error.
2. **Describe entity properties.** Add `description:` to each `@Property` in `LayerEntities.swift`, written for someone who has never seen Layer.
3. **Add the generable spec.** Move `ScreenSpecTool.swift` into `Layer/Intents/`. Its `ScreenSpec` turns into the outline that `BuildScreenIntent` reads, and is built by the same code.
4. **Add the skills.** Move `Skills.skillsbundle` into the app target's resources (an app target can hold only one). Each skill is one folder with one `SKILL.md`.
5. **Card snippets.** Make `DesignEntity` and `ScreenEntity` `SnippetRepresentableEntity`, returning a `CardSnippet` that shows the design's stored thumbnail or the screen drawn with `ScreenView`.
6. **Model toolset reference.** `docs/automation.md` lists every action, its units and the stroke and look formats, written for a model choosing tools.
7. **Test on a device**, not the Simulator, with Siri Evaluations scenarios for each request in the plan doc. Run the build-screen set against `AppleIntelligenceInterpreter` as the benchmark.
