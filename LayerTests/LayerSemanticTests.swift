import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Semantic UI")
struct LayerSemanticTests {
    @Test func reconciliationPreservesStableIDsWithoutErasingUserNames() {
        let original = LayerNode(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .button,
            name: "User edited",
            props: .init(text: "Continue"),
            isLocked: true
        )
        let generated = LayerNode(kind: .button, props: .init(text: "Continue"))

        let reconciled = LayerNode.reconcile(existing: [original], generated: [generated])

        #expect(reconciled.count == 1)
        #expect(reconciled[0].id == original.id)
        #expect(reconciled[0].isLocked)
    }

    @Test func reconciliationKeepsAnUserEditedNodeByStableIdentity() {
        let external = "continue"
        let original = LayerNode(
            kind: .button,
            externalID: external,
            props: .init(text: "My label"),
            isUserEdited: true
        )
        let generated = LayerNode(kind: .button, externalID: external, props: .init(text: "Continue"))

        let reconciled = LayerNode.reconcile(existing: [original], generated: [generated])

        #expect(reconciled == [original])
    }

    @Test func layoutResolvesNestedGridAndPreservesAsymmetricFreeformFrame() {
        let asymmetric = CGRect(x: 31, y: 170, width: 137, height: 44)
        let freeform = LayerNode(
            kind: .freeform,
            layout: .init(kind: .leaf),
            sketchIntent: .init(originalBounds: asymmetric, normalizedBounds: nil, provenance: "pencil", confidence: 1, placementIsAuthoritative: true),
            resolvedFrame: asymmetric
        )
        let grid = LayerNode(
            kind: .grid,
            children: [
                .init(kind: .text, props: .init(text: "A")),
                .init(kind: .text, props: .init(text: "B")),
                .init(kind: .text, props: .init(text: "C")),
                .init(kind: .text, props: .init(text: "D")),
            ],
            layout: .init(kind: .grid, columns: 2, spacing: 12)
        )

        let (resolved, validation) = LayerLayoutEngine.resolve([freeform, grid], in: CGRect(x: 0, y: 0, width: 393, height: 852))

        #expect(validation.clippingCount == 0)
        #expect(resolved[0].resolvedFrame == asymmetric)
        #expect(resolved[1].children.count == 4)
    }

    @Test func layoutKeepsTwoTopLevelGroupsAndNestedContentNonoverlapping() {
        let card = LayerNode(
            kind: .card,
            children: [
                .init(kind: .title, props: .init(text: "Account")),
                .init(kind: .textField, props: .init(placeholder: "Name")),
            ],
            layout: .init(kind: .column, width: .init(sizing: .fill), height: .init(sizing: .intrinsic), padding: 16, spacing: 12)
        )
        let actions = LayerNode(
            kind: .row,
            children: [
                .init(kind: .button, props: .init(text: "Cancel")),
                .init(kind: .button, props: .init(text: "Save")),
            ],
            layout: .init(kind: .row, width: .init(sizing: .fill), height: .init(sizing: .fixed, value: 44), spacing: 12)
        )

        let (resolved, validation) = LayerLayoutEngine.resolve([card, actions], in: CGRect(x: 0, y: 0, width: 393, height: 852))

        #expect(validation.clippingCount == 0)
        let first = try! #require(resolved[0].resolvedFrame)
        let second = try! #require(resolved[1].resolvedFrame)
        #expect(!first.intersects(second))
        #expect(resolved[0].children.count == 2)
    }

    @Test func spatialInferenceCreatesRowAndKeepsAsymmetricPositionsOutsideTheRow() {
        let left = LayerNode(kind: .button, resolvedFrame: CGRect(x: 40, y: 300, width: 120, height: 44))
        let right = LayerNode(kind: .button, resolvedFrame: CGRect(x: 230, y: 301, width: 120, height: 44))

        let inferred = SketchSpatialInference.infer(from: [left, right])

        #expect(inferred.count == 1)
        #expect(inferred[0].kind == .row)
        #expect(inferred[0].children.count == 2)

        let asymmetric = LayerNode(kind: .button, resolvedFrame: CGRect(x: 31, y: 170, width: 137, height: 44))
        #expect(SketchSpatialInference.infer(from: [left, asymmetric]).contains(where: { $0.kind == .button }))
    }

    @Test func semanticDocumentRoundTripsWithoutLoosingStableIDs() throws {
        let id = UUID()
        let screen = DesignScreen(
            name: "Screen",
            origin: .zero,
            scale: 1,
            deviceID: nil,
            elements: [],
            semanticNodes: [.init(id: id, kind: .card, children: [.init(kind: .text, props: .init(text: "Hello"))])]
        )
        let data = try JSONEncoder().encode(screen)
        let decoded = try JSONDecoder().decode(DesignScreen.self, from: data)

        #expect(decoded.semanticNodes.first?.id == id)
        #expect(decoded.semanticNodes.first?.children.first?.props.text == "Hello")
    }

    @Test func a2UIImportMapsSupportedNodesAndReportsUnsupportedComponents() {
        let json = """
        {"createSurface":{
          "surfaceId":"main",
          "catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
          "components":[
            {"id":"root","component":"Column","children":["title","continue"]},
            {"id":"title","component":"Text","text":"Hello"},
            {"id":"continue","component":"Button","text":"Continue"},
            {"id":"unsupported","component":"Unknown","text":"ignored"}
          ]
        }}
        """.data(using: .utf8)!

        let result = A2UIBoundary.importJSON(json)

        #expect(result.roots.count == 1)
        #expect(result.roots[0].kind == .column)
        #expect(result.roots[0].children.map(\.kind) == [.text, .button])
        #expect(result.diagnostics.contains { $0.message.contains("Unknown") })
    }

    @Test func a2UIImportReportsCycleAndUnresolvedReferences() {
        let json = """
        {"updateComponents":{
          "surfaceId":"main",
          "components":[
            {"id":"root","component":"Column","children":["missing","root"]}
          ]
        }}
        """.data(using: .utf8)!

        let result = A2UIBoundary.importJSON(json)

        #expect(result.roots.count == 1)
        #expect(result.diagnostics.contains { $0.message.contains("Unresolved") })
        #expect(result.diagnostics.contains { $0.message.contains("cycle") })
    }

    @Test func swiftUIExportUsesRecursiveStacksGridAndOverlay() {
        let screen = DesignScreen(
            name: "Semantic Screen",
            origin: .zero,
            scale: 1,
            deviceID: nil,
            elements: [],
            semanticNodes: [
                .init(kind: .column, children: [
                    .init(kind: .row, children: [
                        .init(kind: .text, props: .init(text: "Left")),
                        .init(kind: .text, props: .init(text: "Right")),
                    ]),
                    .init(kind: .grid, children: [
                        .init(kind: .button, props: .init(text: "One")),
                        .init(kind: .button, props: .init(text: "Two")),
                    ], layout: .init(kind: .grid, columns: 2)),
                    .init(kind: .overlay, children: [.init(kind: .image)]),
                ])
            ]
        )

        let code = SwiftUICodeGenerator.code(for: screen)

        #expect(code.contains("VStack"))
        #expect(code.contains("HStack"))
        #expect(code.contains("LazyVGrid"))
        #expect(code.contains("ZStack"))
        #expect(code.contains("Button(\"One\")"))
    }
}

@Suite("Sketch semantic undo")
@MainActor
struct SketchSemanticUndoTests {
    @Test func addElementAndGroupingShareOneUndoStep() {
        let store = DesignStore()
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let screen = store.addScreen(from: CGRect(x: 400, y: 125, width: 270, height: 584))
        let sketch = CGRect(x: 480, y: 200, width: 120, height: 44)

        _ = store.addElement(.button, from: sketch, to: screen.id)

        #expect(store.screen(screen.id)?.semanticNodes.count == 1)
        undo.undo()
        #expect(store.screen(screen.id)?.elements.isEmpty == true)
        #expect(store.screen(screen.id)?.semanticNodes.isEmpty == true)
    }
}
