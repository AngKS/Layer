import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct TreeValidatorTests {
    private let device = DeviceFrame.iPhone

    // MARK: - Building trees

    private func leaf(_ kind: ElementKind = .shape, _ x: CGFloat = 0, _ y: CGFloat = 0,
                      _ width: CGFloat = 50, _ height: CGFloat = 50) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = CGRect(x: x, y: y, width: width, height: height)
        return node
    }

    private func root(_ children: [LayerNode]) -> LayerNode {
        var node = LayerNode(kind: .group)
        node.layout = .free
        node.frame = CGRect(origin: .zero, size: device.size)
        node.children = children
        return node
    }

    private func kinds(_ issues: [TreeValidator.Issue]) -> Set<String> {
        Set(issues.map { "\($0.kind)" })
    }

    private func depth(of node: LayerNode) -> Int {
        var deepest = 0
        var stack = [(node, 0)]
        while let (current, level) = stack.popLast() {
            deepest = max(deepest, level)
            stack += current.children.map { ($0, level + 1) }
        }
        return deepest
    }

    private func count(_ node: LayerNode) -> Int {
        var total = 0
        var stack = [node]
        while let current = stack.popLast() {
            total += 1
            stack += current.children
        }
        return total
    }

    private func readingOrder(_ node: LayerNode) -> [UUID] {
        var order: [UUID] = []
        var stack = [node]
        while let current = stack.popLast() {
            order.append(current.id)
            stack += current.children.reversed()
        }
        return order
    }

    // MARK: - check

    @Test func aSoundTreeHasNoIssues() {
        #expect(TreeValidator.check(root([leaf(.title, 20, 20, 200, 30), leaf(.button, 20, 100, 200, 44)]), on: device).isEmpty)
    }

    @Test func aChildUnderALeafIsNotAllowed() {
        var parent = leaf(.shape)
        let child = leaf(.shape)
        parent.children = [child]
        let issues = TreeValidator.check(root([parent]), on: device)
        #expect(issues == [TreeValidator.Issue(node: child.id, kind: .notAllowedHere)])
    }

    @Test func aDrawingInsideTheRootIsNotAllowed() {
        let drawing = leaf(.drawing)
        let issues = TreeValidator.check(root([drawing]), on: device)
        #expect(issues == [TreeValidator.Issue(node: drawing.id, kind: .notAllowedHere)])
        // A top-level canvas node may itself be one.
        #expect(TreeValidator.check(drawing, on: nil).isEmpty)
    }

    @Test func aTreeDeeperThan32IsTooDeep() {
        var node = leaf()
        for _ in 0..<TreeRules.maximumDepth { // 32 groups above the leaf: the leaf sits at depth 32
            var group = LayerNode(kind: .group)
            group.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
            group.children = [node]
            node = group
        }
        #expect(depth(of: node) == 32)
        #expect(TreeValidator.check(node, on: nil).isEmpty)
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        group.children = [node]
        #expect(kinds(TreeValidator.check(group, on: nil)) == ["tooDeep"])
    }

    @Test func moreThan5000NodesAreTooMany() {
        let tree = root((0..<TreeRules.maximumNodes).map { _ in leaf() })
        #expect(count(tree) == 5_001)
        let issues = TreeValidator.check(tree, on: nil)
        #expect(kinds(issues) == ["tooMany"])
        #expect(issues.first?.node == tree.children.last?.id)
    }

    @Test func badNumbersAreBadGeometry() {
        var width = leaf(); width.frame.size.width = .nan
        var height = leaf(); height.frame.size.height = -1
        var padded = root([]); padded.padding.top = -4
        var spaced = LayerNode(kind: .group); spaced.layout = .stack(.init(axis: .vertical, spacing: .infinity))
        spaced.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        var columns = LayerNode(kind: .group); columns.layout = .grid(.init(columns: 50))
        columns.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        for node in [width, height, spaced, columns] {
            #expect(TreeValidator.check(root([node]), on: device).contains(.init(node: node.id, kind: .badGeometry)))
        }
        #expect(TreeValidator.check(padded, on: device).contains(.init(node: padded.id, kind: .badGeometry)))
    }

    @Test func aNodeOutsideTheDeviceIsClipped() {
        let outside = leaf(.shape, 380, 100, 50, 50)
        let inside = leaf(.shape, 100, 100, 50, 50)
        let tree = root([inside, outside])
        #expect(TreeValidator.check(tree, on: device) == [.init(node: outside.id, kind: .clipped)])
        #expect(TreeValidator.check(tree, on: nil).isEmpty)
    }

    @Test func clippingIsMeasuredFromTheScreenNotTheParent() {
        var group = LayerNode(kind: .group)
        group.frame = CGRect(x: 300, y: 0, width: 90, height: 90)
        let child = leaf(.shape, 50, 10, 30, 30) // 350..380 on screen: inside
        let past = leaf(.shape, 70, 10, 30, 30) // 370..400: past 393
        group.children = [child, past]
        #expect(TreeValidator.check(root([group]), on: device) == [.init(node: past.id, kind: .clipped)])
    }

    @Test func textUnder11PointsIsSmall() {
        var small = leaf(.body, 0, 0, 100, 20); small.style.fontSize = 10
        var fine = leaf(.body, 0, 30, 100, 20); fine.style.fontSize = 11
        #expect(TreeValidator.check(root([small, fine]), on: device) == [.init(node: small.id, kind: .smallText)])
    }

    @Test func aButtonOrTextFieldUnder44IsSmall() {
        let button = leaf(.button, 0, 0, 100, 40)
        let field = leaf(.textField, 0, 60, 100, 43)
        let fine = leaf(.button, 0, 120, 100, 44)
        let issues = TreeValidator.check(root([button, field, fine]), on: device)
        #expect(issues == [.init(node: button.id, kind: .smallControl), .init(node: field.id, kind: .smallControl)])
    }

    @Test func checkNeverChangesTheTree() {
        var bad = leaf(.button, 400, 0, .nan, 10)
        bad.children = [leaf(.drawing)]
        let tree = root([bad])
        let before = tree
        _ = TreeValidator.check(tree, on: device)
        #expect(tree == before)
    }

    // MARK: - fixGenerated

    @Test func fixGeneratedFixesAndReports() {
        var badNumbers = leaf(.shape, 10, 10, .nan, -5)
        badNumbers.id = UUID()
        var columns = LayerNode(kind: .card); columns.layout = .grid(.init(columns: 50, columnSpacing: .nan, rowSpacing: -3))
        columns.frame = CGRect(x: 0, y: 200, width: 100, height: 100)
        columns.padding = .init(top: -1, leading: .infinity, bottom: 0, trailing: 0)
        var spaced = LayerNode(kind: .group); spaced.layout = .stack(.init(axis: .vertical, spacing: -8))
        spaced.frame = CGRect(x: 0, y: 300, width: 100, height: 100)
        var zeroColumns = LayerNode(kind: .group); zeroColumns.layout = .grid(.init(columns: 0))
        zeroColumns.frame = CGRect(x: 0, y: 400, width: 100, height: 100)
        let button = leaf(.button, 0, 500, 100, 30)
        let field = leaf(.textField, 0, 540, 100, 20)
        var text = leaf(.body, 0, 600, 100, 20); text.style.fontSize = 8
        var parent = leaf(.shape, 0, 650, 50, 50); parent.children = [leaf()]
        let tree = root([badNumbers, columns, spaced, zeroColumns, button, field, text, parent])
        var fixed = tree
        let issues = TreeValidator.fixGenerated(&fixed)
        #expect(kinds(issues).isSuperset(of: ["badGeometry", "smallControl", "smallText", "notAllowedHere"]))
        #expect(TreeValidator.check(fixed, on: device).allSatisfy { $0.kind == .clipped })
        let found = fixed.children
        #expect(found[0].frame.size == .zero)
        #expect(found[1].layout == .grid(.init(columns: 12)))
        #expect(found[1].padding == .init(top: 0, leading: 0, bottom: 0, trailing: 0))
        #expect(found[2].layout == .stack(.init(axis: .vertical, spacing: 0)))
        #expect(found[3].layout == .grid(.init(columns: 1)))
        #expect(found[4].frame.height == 44 && found[5].frame.height == 44)
        #expect(found[6].style.fontSize == 11)
        #expect(found[7].children.isEmpty)
        // Fixing again finds nothing to fix.
        var again = fixed
        #expect(TreeValidator.fixGenerated(&again).isEmpty)
        #expect(again == fixed)
    }

    @Test func controlsTheLayoutSizesAreLeftToIt() {
        // Before layout a fit or fill height reads as 0; the layout gives a control its natural height.
        var fitButton = leaf(.button, 0, 0, 100, 0)
        fitButton.height = .init(.fit)
        var fillField = leaf(.textField, 0, 60, 100, 0)
        fillField.height = .init(.fill(weight: 1))
        // One the layout could only make short, and one fixed short, are raised.
        var capped = leaf(.button, 0, 120, 100, 0)
        capped.height = .init(.fit, maximum: 30)
        let fixedButton = leaf(.button, 0, 200, 100, 30)
        var fixed = root([fitButton, fillField, capped, fixedButton])

        let issues = TreeValidator.fixGenerated(&fixed)
        #expect(issues == [.init(node: capped.id, kind: .smallControl), .init(node: fixedButton.id, kind: .smallControl)])
        #expect(fixed.children[0] == fitButton)
        #expect(fixed.children[1] == fillField)
        #expect(fixed.children[2].height == .init(.fit, maximum: 44))
        #expect(fixed.children[3].frame.height == 44)
    }

    @Test func hugeNumbersAreBroughtIntoRange() throws {
        let far = leaf(.shape, 1e308, -1e308, 1e308, .greatestFiniteMagnitude)
        var padded = LayerNode(kind: .group)
        padded.layout = .stack(.init(axis: .vertical, spacing: 1e308))
        padded.padding = .init(all: 1e308)
        padded.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var cells = LayerNode(kind: .group)
        cells.layout = .grid(.init(columns: 3, columnSpacing: 1e308, rowSpacing: 1e308))
        cells.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        cells.children = Array(repeating: leaf(.shape, 0, 0, 10, 10), count: 4)
        var styled = leaf(.body, 0, 0, 100, 20)
        styled.style.fontSize = 1e308
        styled.style.cornerRadius = 1e308
        styled.style.borderWidth = .infinity
        styled.style.opacity = .nan
        var progress = leaf(.progress)
        progress.content.value = 1e308
        var turned = leaf()
        turned.rotation = .infinity
        var sized = leaf()
        sized.width = .init(.fill(weight: 1e308), minimum: 1e308, maximum: .nan)
        var tree = root([far, padded, cells, styled, progress, turned, sized])

        let issues = TreeValidator.fixGenerated(&tree)
        for node in [far, padded, cells, styled, progress, turned, sized] {
            #expect(issues.contains(.init(node: node.id, kind: .badGeometry)), "\(node.kind)")
        }
        let found = tree.children
        #expect(found[0].frame == CGRect(x: 1_000_000, y: -1_000_000, width: 1_000_000, height: 1_000_000))
        #expect(found[1].padding == .init(all: 10_000))
        #expect(found[1].layout == .stack(.init(axis: .vertical, spacing: 10_000)))
        #expect(found[2].layout == .grid(.init(columns: 3, columnSpacing: 10_000, rowSpacing: 10_000)))
        #expect(found[3].style.fontSize == 1_000)
        #expect(found[3].style.cornerRadius == 10_000)
        #expect(found[3].style.borderWidth == nil)
        #expect(found[3].style.opacity == nil)
        #expect(found[4].content.value == 1)
        #expect(found[5].rotation == nil)
        #expect(found[6].width == .init(.fill(weight: 1_000_000), minimum: 1_000_000))
        // Fixing again finds nothing.
        var again = tree
        #expect(TreeValidator.fixGenerated(&again).isEmpty)

        // Laid out, nothing is infinite, so the design can be saved.
        var diagnostics: [LayoutDiagnostic] = []
        LayoutEngine.layOut(&tree, previous: nil, measure: .shared, diagnostics: &diagnostics)
        var frames: [CGRect] = []
        var pending = [tree]
        while let node = pending.popLast() {
            frames.append(node.frame)
            pending += node.children
        }
        #expect(frames.allSatisfy { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) })
        #expect(throws: Never.self) { _ = try JSONEncoder().encode(tree) }
    }

    @Test func aSoundTreeIsLeftAloneByFixGenerated() {
        let tree = root([leaf(.title, 20, 20, 200, 30), leaf(.button, 20, 100, 200, 44)])
        var copy = tree
        #expect(TreeValidator.fixGenerated(&copy).isEmpty)
        #expect(copy == tree)
    }

    @Test func aFortyDeepTreeIsFlattenedTo32() {
        // 40 nested groups, each also holding one leaf: 40 leaves, 40 groups, the first group is the root.
        var node = LayerNode(kind: .group)
        node.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        node.children = [leaf()]
        for _ in 1..<40 {
            var group = LayerNode(kind: .group)
            group.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
            group.children = [leaf(), node]
            node = group
        }
        let order = readingOrder(node)
        #expect(depth(of: node) == 40)
        let issues = TreeValidator.fixGenerated(&node)
        #expect(depth(of: node) == 32)
        #expect(kinds(issues) == ["tooDeep"])
        #expect(count(node) == order.count)
        #expect(readingOrder(node) == order)
        #expect(node.children.isEmpty == false)
        var leaves = 0
        var stack = [node]
        while let current = stack.popLast() {
            if current.kind == .shape { leaves += 1 }
            stack += current.children
        }
        #expect(leaves == 40)
        #expect(TreeValidator.check(node, on: nil).isEmpty)
    }

    @Test func aVeryDeepTreeIsSafe() {
        var node = leaf()
        for _ in 0..<4_000 {
            var group = LayerNode(kind: .group)
            group.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
            group.children = [node]
            node = group
        }
        #expect(TreeValidator.check(node, on: nil).contains { $0.kind == .tooDeep })
        let issues = TreeValidator.fixGenerated(&node)
        #expect(kinds(issues) == ["tooDeep"])
        #expect(depth(of: node) == 32)
        #expect(count(node) == 4_001)
    }

    @Test func sixThousandNodesAreCutTo5000() {
        let tree = root((0..<5_999).map { _ in leaf() })
        let order = readingOrder(tree)
        #expect(order.count == 6_000)
        var cut = tree
        let issues = TreeValidator.fixGenerated(&cut)
        #expect(kinds(issues) == ["tooMany"])
        #expect(readingOrder(cut) == Array(order.prefix(TreeRules.maximumNodes)))
    }
}
