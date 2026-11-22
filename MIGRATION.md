# Sketch-first semantic UI migration

This branch introduces the `LayerNode` semantic document model as the canonical
tree for sketch and import boundaries. `DesignElement` remains the live flat
rendering compatibility view while the semantic migration is completed.

## Document model

- `LayerNode` is stable-ID, typed, hierarchical, and carries layout, style,
  accessibility, sketch provenance, and a resolved frame cache.
- `LayerNode.LayoutSpec` supports leaf, row, column, card, grid, and overlay.
- `LayerLayoutEngine` resolves nested geometry off the legacy row assumptions.
- `SketchSpatialInference` creates containers only for confident horizontal
  adjacency or repeated-grid relationships. Low-confidence structures remain
  detached/freeform nodes.

## Sketch and import boundaries

- Rule/Handwriting/Apple Intelligence recognition remains on the existing
  `SketchEngine` path. It does not import or execute A2UI.
- `A2UIBoundary` maps supported A2UI JSON components into `LayerNode`.
  Unsupported components are reported as diagnostics. Actions and RPC are never
  executed.
- The project pins official A2UI Swift `0.11.0` with only `A2UISwiftCore` and
  `BasicCatalog`; `A2UISwiftUI` is not part of the editor.

## Breaking scope

The new semantic data is written under `semanticNodes` in `design.json`.
Backwards compatibility with historical `.layer` documents and `ScreenBlueprint`
is not required. Existing ink and picture package files remain separate and
unchanged. Legacy `DesignElement` data is still used by the live canvas during
this vertical slice.

`PhoneScreenView` now resolves `semanticNodes` and uses their resolved leaf
frames when present, while `DesignElement` remains the editable interaction
payload and stable-ID synchronization source. Move, resize, text/style edits,
delete, host changes, and generation reconcile both representations in the
same store transaction. This vertical slice does not claim that every legacy
editing path has already migrated to a fully recursive SwiftUI canvas renderer.

## Verification

Run with Xcode 27.2 or later:

```sh
xcodegen generate
xcodebuild -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,name=<available iPad simulator>" test
```

Performance notes and any Xcode-unavailable results should be recorded in the
draft PR rather than inferred.
