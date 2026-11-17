import CoreGraphics
import Foundation
import PencilKit
import Testing
@testable import Layer

private func element(_ kind: ElementKind, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> DesignElement {
    DesignElement(kind: kind, frame: CGRect(x: x, y: y, width: width, height: height), text: kind.placeholder, tint: Theme.accent)
}

/// A loop drawn round an area, corner to corner.
private func loop(round rect: CGRect) -> [CGPoint] {
    [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
    ]
}

private func inkStroke(_ points: [CGPoint]) -> PKStroke {
    let controls = points.enumerated().map { offset, point in
        PKStrokePoint(location: point, timeOffset: Double(offset) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: controls, creationDate: InkGeometry.newStrokeDate()))
}

/// A board with a screen at (100, 50), drawn at half size, that holds a title, some body
/// text and a button, and a sticky note on the open canvas beside it.
@MainActor
private struct Board {
    let model: AppModel
    let undo = UndoManager()
    let screen: DesignScreen.ID
    let title: DesignStore.ElementRef
    let body: DesignStore.ElementRef
    let button: DesignStore.ElementRef
    let note: DesignStore.ElementRef

    var store: DesignStore { model.store }

    init() {
        model = AppModel(document: LayerDocument())
        model.canvasSize = CGSize(width: 1210, height: 834)
        screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 50), scale: 0.5)).id
        let placed = model.store.setElements([
            element(.title, 80, 100, 228, 40),
            element(.body, 40, 200, 300, 60),
            element(.button, 28, 700, 337, 60),
        ], on: screen, replacing: true)
        (title, body, button) = (placed[0], placed[1], placed[2])
        note = model.store.addFloating(element(.stickyNote, 500, 100, 140, 130), scale: 1)
        // Building the board is not something these tests undo.
        undo.groupsByEvent = false
        model.store.undoManager = undo
    }

    func canvasFrame(_ ref: DesignStore.ElementRef) -> CGRect {
        store.canvasFrame(of: .element(ref)) ?? .null
    }
}

struct SeveralThingsSelectedTests {
    private let screen = UUID()
    private let other = UUID()

    private func onScreen(_ id: UUID = UUID()) -> CanvasSelection {
        .element(.init(host: .screen(screen), element: id))
    }

    @Test func noThingsAreNoSelectionAndOneThingIsItself() {
        let title = onScreen()
        #expect(CanvasSelection([]) == nil)
        #expect(CanvasSelection([title]) == title)
        #expect(CanvasSelection([title, title]) == title)
    }

    @Test func severalThingsAreOneSelectionWhateverOrderTheyWerePickedIn() throws {
        let title = onScreen(), button = onScreen()
        let selection = try #require(CanvasSelection([title, button]))
        #expect(selection == CanvasSelection([button, title]))
        #expect(selection.things == [title, button])
        #expect(selection.contains(title))
        #expect(!selection.contains(onScreen()))
        #expect(selection != title)
    }

    @Test func anElementWhoseScreenIsSelectedIsNotSelectedApartFromIt() {
        let title = onScreen()
        let note = CanvasSelection.element(.init(host: .canvas, element: UUID()))
        let elsewhere = CanvasSelection.element(.init(host: .screen(other), element: UUID()))
        let selection = CanvasSelection([.screen(screen), title, note, elsewhere])
        #expect(selection?.things == [.screen(screen), note, elsewhere])
    }

    @Test func aThingIsAddedByTogglingItAndTakenOutByTogglingItAgain() {
        let title = onScreen(), button = onScreen(), body = onScreen()
        let two = title.toggling(button)
        #expect(two == CanvasSelection([title, button]))
        #expect(two?.toggling(body)?.things == [title, button, body])
        #expect(two?.toggling(title) == button)
        #expect(title.toggling(title) == nil)
    }

    @Test func aSelectionMadeOfSelectionsIsMadeOfTheirThings() {
        let title = onScreen(), button = onScreen(), body = onScreen()
        let nested = CanvasSelection([CanvasSelection([title, button])!, body])
        #expect(nested?.things == [title, button, body])
    }
}

struct LiningUpTests {
    private let frames = [
        CGRect(x: 10, y: 40, width: 100, height: 20),
        CGRect(x: 60, y: 100, width: 40, height: 60),
        CGRect(x: 200, y: 10, width: 50, height: 30),
    ]

    @Test func framesLineUpWithTheEdgesOfTheAreaTheyCoverTogether() {
        #expect(ElementLayout.aligned(frames, .left).map(\.minX) == [10, 10, 10])
        #expect(ElementLayout.aligned(frames, .right).map(\.maxX) == [250, 250, 250])
        #expect(ElementLayout.aligned(frames, .top).map(\.minY) == [10, 10, 10])
        #expect(ElementLayout.aligned(frames, .bottom).map(\.maxY) == [160, 160, 160])
    }

    @Test func framesLineUpThroughTheMiddleOfTheAreaTheyCoverTogether() {
        #expect(ElementLayout.aligned(frames, .centerX).map(\.midX) == [130, 130, 130])
        #expect(ElementLayout.aligned(frames, .centerY).map(\.midY) == [85, 85, 85])
    }

    @Test func liningUpChangesOnlyWhereFramesAreNotHowLargeTheyAre() {
        for alignment in ElementLayout.Alignment.allCases {
            #expect(ElementLayout.aligned(frames, alignment).map(\.size) == frames.map(\.size))
        }
        // Across leaves the height of each where it was, and the other way about.
        #expect(ElementLayout.aligned(frames, .left).map(\.minY) == frames.map(\.minY))
        #expect(ElementLayout.aligned(frames, .top).map(\.minX) == frames.map(\.minX))
    }

    @Test func framesAreSpacedEvenlyBetweenTheFirstAndTheLast() {
        // Given out of order: the middle one is the one that moves.
        let row = [
            CGRect(x: 90, y: 0, width: 10, height: 10),
            CGRect(x: 15, y: 30, width: 10, height: 10),
            CGRect(x: 0, y: 60, width: 10, height: 10),
        ]
        let spread = ElementLayout.distributed(row, .horizontal)
        #expect(spread.map(\.minX) == [90, 45, 0])
        #expect(spread.map(\.minY) == row.map(\.minY))

        let column = row.map { CGRect(x: $0.minY, y: $0.minX, width: 10, height: 10) }
        #expect(ElementLayout.distributed(column, .vertical).map(\.minY) == [90, 45, 0])
    }

    @Test func framesOfDifferentSizesAreSpacedByTheGapsBetweenThem() {
        let row = [
            CGRect(x: 0, y: 0, width: 20, height: 10),
            CGRect(x: 25, y: 0, width: 60, height: 10),
            CGRect(x: 180, y: 0, width: 20, height: 10),
        ]
        let spread = ElementLayout.distributed(row, .horizontal)
        // 200 across, 100 of it frames: a gap of 50 either side of the middle one.
        #expect(spread.map(\.minX) == [0, 70, 180])
    }

    @Test func twoFramesHaveNothingToBeSpacedBetween() {
        let pair = Array(frames.prefix(2))
        #expect(ElementLayout.distributed(pair, .horizontal) == pair)
    }
}

struct EnclosureTests {
    private let square = loop(round: CGRect(x: 0, y: 0, width: 100, height: 100))

    @Test func aLoopHoldsThePointsInsideIt() {
        #expect(Enclosure.contains(square, CGPoint(x: 50, y: 50)))
        #expect(!Enclosure.contains(square, CGPoint(x: 150, y: 50)))
        #expect(!Enclosure.contains(square, CGPoint(x: 50, y: -1)))
    }

    @Test func aLoopThatBendsBackOnItselfLeavesOutTheHollow() {
        // An L: the top-right quarter of the square is outside it.
        let bend = [
            CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50),
            CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
        ]
        #expect(Enclosure.contains(bend, CGPoint(x: 25, y: 25)))
        #expect(Enclosure.contains(bend, CGPoint(x: 75, y: 75)))
        #expect(!Enclosure.contains(bend, CGPoint(x: 75, y: 25)))
    }

    @Test func aLineGoesRoundNothing() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)]
        #expect(!Enclosure.contains(line, CGPoint(x: 50, y: 50)))
        #expect(Enclosure.coverage(of: CGRect(x: 40, y: 40, width: 20, height: 20), by: line) == 0)
    }

    @Test func coverageIsHowMuchOfAnAreaTheLoopGoesRound() {
        #expect(Enclosure.coverage(of: CGRect(x: 20, y: 20, width: 30, height: 30), by: square) == 1)
        #expect(Enclosure.coverage(of: CGRect(x: 200, y: 20, width: 30, height: 30), by: square) == 0)
        let half = Enclosure.coverage(of: CGRect(x: 80, y: 20, width: 40, height: 30), by: square)
        #expect(abs(half - 0.5) < 0.1)
        let quarter = Enclosure.coverage(of: CGRect(x: 90, y: 90, width: 40, height: 40), by: square)
        #expect(abs(quarter - 0.0625) < 0.1)
    }
}

@MainActor
struct PickedByALoopTests {
    @Test func aLoopPicksTheElementsItGoesRound() {
        let board = Board()
        // Round the title and the body text, well short of the button.
        let area = board.canvasFrame(board.title).union(board.canvasFrame(board.body)).insetBy(dx: -6, dy: -6)
        #expect(Set(board.store.things(enclosedBy: loop(round: area))) == [.element(board.title), .element(board.body)])
    }

    @Test func aLoopPicksWhatItHasAtLeastHalfOf() {
        let board = Board()
        let note = board.canvasFrame(board.note)
        let most = CGRect(x: note.minX - 10, y: note.minY - 10, width: note.width * 0.7 + 10, height: note.height + 20)
        #expect(board.store.things(enclosedBy: loop(round: most)) == [.element(board.note)])
        let corner = CGRect(x: note.minX - 10, y: note.minY - 10, width: note.width * 0.4 + 10, height: note.height * 0.5 + 10)
        #expect(board.store.things(enclosedBy: loop(round: corner)).isEmpty)
    }

    @Test func aLoopRoundAWholeScreenPicksTheScreenAndNotWhatIsOnIt() throws {
        let board = Board()
        let frame = try #require(board.store.screen(board.screen)).canvasFrame.insetBy(dx: -10, dy: -10)
        #expect(board.store.things(enclosedBy: loop(round: frame)) == [.screen(board.screen)])
        // With the note beside it in the loop too, both are picked.
        let both = frame.union(board.canvasFrame(board.note)).insetBy(dx: -10, dy: -10)
        #expect(Set(board.store.things(enclosedBy: loop(round: both))) == [.screen(board.screen), .element(board.note)])
    }

    @Test func aLoopInsideAScreenPicksItsElementsAndNotTheScreen() throws {
        let board = Board()
        // Most of the screen, but not all of it: its three elements.
        let frame = try #require(board.store.screen(board.screen)).canvasFrame.insetBy(dx: 10, dy: 30)
        #expect(Set(board.store.things(enclosedBy: loop(round: frame))) == [.element(board.title), .element(board.body), .element(board.button)])
    }

    @Test func lockedAndHiddenThingsAreLeftOutOfALoop() {
        let board = Board()
        board.store.update(board.title) { $0.isLocked = true }
        board.store.update(board.body) { $0.isHidden = true }
        let area = board.canvasFrame(board.title).union(board.canvasFrame(board.button)).insetBy(dx: -6, dy: -6)
        #expect(board.store.things(enclosedBy: loop(round: area)) == [.element(board.button)])
    }

    @Test func aDrawingIsPickedByItsInkAndNotByTheBoxRoundIt() throws {
        let board = Board()
        // An L, down the left side and along the bottom of a 200-point square, well away
        // from everything else.
        let down = (0...20).map { CGPoint(x: 1000, y: 1000 + CGFloat($0) * 10) }
        let along = (1...20).map { CGPoint(x: 1000 + CGFloat($0) * 10, y: 1200) }
        let corner = try #require(DesignElement.drawing([inkStroke(down + along)]))
        let drawing = board.store.addFloating(corner, scale: 1)

        // A band along the L holds all its ink, and a fifth of the box round it.
        let band = [
            CGPoint(x: 990, y: 990), CGPoint(x: 1010, y: 990), CGPoint(x: 1010, y: 1190),
            CGPoint(x: 1210, y: 1190), CGPoint(x: 1210, y: 1210), CGPoint(x: 990, y: 1210),
        ]
        #expect(board.store.things(enclosedBy: band) == [.element(drawing)])

        // The rest of the box is most of it, and holds no ink at all.
        let hollow = loop(round: CGRect(x: 1040, y: 990, width: 170, height: 170))
        #expect(board.store.things(enclosedBy: hollow).isEmpty)
    }
}

@MainActor
struct SeveralThingsChangedTogetherTests {
    @Test func thingsOnAScreenAndOffItLineUpWithOneAnotherOnTheCanvas() throws {
        let board = Board()
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.note)]))
        // The title starts at 140 across the canvas, the note at 500.
        #expect(board.canvasFrame(board.title).minX == 140)

        board.store.align(selection, .left)
        #expect(board.canvasFrame(board.title).minX == 140)
        #expect(board.canvasFrame(board.note).minX == 140)

        board.store.align(selection, .top)
        #expect(board.canvasFrame(board.title).minY == 100)
        #expect(board.canvasFrame(board.note).minY == 100)
    }

    @Test func liningUpIsOneStepToUndo() throws {
        let board = Board()
        let before = board.store.content
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.body), .element(board.button)]))
        board.store.align(selection, .left)
        #expect(Set([board.title, board.body, board.button].map { board.store.resolve($0)?.element.frame.minX }) == [28])
        #expect(board.store.content != before)
        board.undo.undo()
        #expect(board.store.content == before)
    }

    @Test func aLockedThingStaysPutAndTheOthersLineUpWithIt() throws {
        let board = Board()
        board.store.update(board.button) { $0.isLocked = true }
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.button)]))
        board.store.align(selection, .right)
        // The button's right edge was the furthest right, and the title joins it there.
        #expect(board.store.resolve(board.button)?.element.frame == CGRect(x: 28, y: 700, width: 337, height: 60))
        #expect(board.store.resolve(board.title)?.element.frame.maxX == 365)

        board.store.align(selection, .left)
        #expect(board.store.resolve(board.button)?.element.frame.minX == 28)
        #expect(board.store.resolve(board.title)?.element.frame.minX == 28)
    }

    @Test func aLockedThingIsNotMovedToLineUpWithTheOthers() throws {
        let board = Board()
        board.store.update(board.title) { $0.isLocked = true }
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.body), .element(board.button)]))
        board.store.align(selection, .left)
        // The body joins the button at the edge furthest left. The title would too, but for its lock.
        #expect(board.store.resolve(board.body)?.element.frame.minX == 28)
        #expect(board.store.resolve(board.title)?.element.frame == CGRect(x: 80, y: 100, width: 228, height: 40))
    }

    @Test func screensLineUpWithEachOther() throws {
        let board = Board()
        let second = board.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 700, y: 400), scale: 0.5))
        let selection = try #require(CanvasSelection([.screen(board.screen), .screen(second.id)]))
        board.store.align(selection, .top)
        #expect(board.store.screen(second.id)?.origin == CGPoint(x: 700, y: 50))
        // What is on a screen goes with it, and keeps its place on it.
        #expect(board.store.resolve(board.title)?.element.frame == CGRect(x: 80, y: 100, width: 228, height: 40))
    }

    @Test func thingsAreSpacedEvenlyDownTheScreen() throws {
        let board = Board()
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.body), .element(board.button)]))
        board.store.distribute(selection, .vertical)
        // From 100 down to 760 with 160 points of elements: a gap of 250 above and below the body.
        #expect(board.store.resolve(board.title)?.element.frame.minY == 100)
        #expect(board.store.resolve(board.body)?.element.frame.minY == 390)
        #expect(board.store.resolve(board.button)?.element.frame.minY == 700)
    }

    @Test func thingsPutSomewhereKeepTheirPlacesRelativeToEachOther() throws {
        let board = Board()
        let things: [CanvasSelection] = [.element(board.title), .element(board.body), .element(board.note)]
        var origins: [CanvasSelection: CGPoint] = [:]
        for thing in things {
            let frame = try #require(board.store.canvasFrame(of: thing))
            origins[thing] = CGPoint(x: frame.minX + 31, y: frame.minY - 17)
        }
        board.store.position(origins)
        // 31 canvas points is 62 of the half-size screen's own.
        #expect(board.store.resolve(board.title)?.element.frame.origin == CGPoint(x: 142, y: 66))
        #expect(board.store.resolve(board.body)?.element.frame.origin == CGPoint(x: 102, y: 166))
        #expect(board.store.resolve(board.note)?.element.frame.origin == CGPoint(x: 531, y: 83))
    }

    @Test func aChangeIsMadeToEveryElementGivenAsOneStep() {
        let board = Board()
        let before = board.store.content
        let red = RGBColor(hex: 0xFF0000)
        board.store.update([board.title, board.button, board.note]) { $0.tint = red }
        #expect([board.title, board.button, board.note].map { board.store.resolve($0)?.element.tint } == [red, red, red])
        #expect(board.store.resolve(board.body)?.element.tint != red)
        board.undo.undo()
        #expect(board.store.content == before)
    }

    @Test func severalThingsAreCopiedInOneStepAndTheCopiesAreWhatComeBack() throws {
        let board = Board()
        let before = board.store.content
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.note)]))
        let copies = try #require(board.store.duplicate(selection))
        #expect(copies.things.count == 2)
        #expect(copies.things.isDisjoint(with: selection.things))
        #expect(board.store.screen(board.screen)?.elements.count == 4)
        #expect(board.store.floating.count == 2)
        board.undo.undo()
        #expect(board.store.content == before)
    }

    @Test func severalThingsAreDeletedInOneStepAndLockedOnesAreLeft() throws {
        let board = Board()
        board.store.update(board.body) { $0.isLocked = true }
        let before = board.store.content
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.body), .element(board.note)]))
        board.store.delete(selection)
        #expect(board.store.resolve(board.title) == nil)
        #expect(board.store.resolve(board.note) == nil)
        #expect(board.store.resolve(board.body) != nil)
        board.undo.undo()
        #expect(board.store.content == before)
    }

    @Test func thingsMovedOffTheirScreenBelongToWhatTheyNowLieOn() throws {
        let board = Board()
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.body)]))
        // Out to the right of the screen, onto the open canvas.
        board.store.position([
            .element(board.title): CGPoint(x: 800, y: 300),
            .element(board.body): CGPoint(x: 800, y: 400),
        ])
        let rehomed = try #require(board.store.rehost(selection))
        #expect(rehomed.things.count == 2)
        #expect(board.store.screen(board.screen)?.elements.count == 1)
        for thing in rehomed.things {
            guard case .element(let ref) = thing else { continue }
            #expect(ref.host == .canvas)
            #expect(board.store.resolve(ref) != nil)
        }
    }
}

@MainActor
struct SeveralThingsOnTheCanvasTests {
    @Test func aLoopDrawnRoundThingsSelectsThem() {
        let board = Board()
        let area = board.canvasFrame(board.title).union(board.canvasFrame(board.body)).insetBy(dx: -6, dy: -6)
        board.model.select(enclosedBy: loop(round: area))
        #expect(board.model.selection == CanvasSelection([.element(board.title), .element(board.body)]))
        // No one of them is the selected element; together they are the selected elements.
        #expect(board.model.selectedElement == nil)
        #expect(board.model.selectedElements.map(\.ref) == [board.title, board.body])
    }

    @Test func aLoopRoundNothingLetsGoOfWhatWasSelected() {
        let board = Board()
        board.model.selection = .element(board.title)
        board.model.select(enclosedBy: loop(round: CGRect(x: 3000, y: 3000, width: 100, height: 100)))
        #expect(board.model.selection == nil)
    }

    @Test func theSelectionCoversEverythingInIt() throws {
        let board = Board()
        board.model.selection = CanvasSelection([.element(board.title), .element(board.note)])
        let rect = try #require(board.model.selectionViewRect)
        #expect(rect == board.canvasFrame(board.title).union(board.canvasFrame(board.note)))
    }

    @Test func tappingWhileAFingerRestsOnSomethingAddsToTheSelection() {
        let board = Board()
        board.model.tool = .select
        // One finger rests on the title while another taps.
        board.model.restingFingers = { [CGPoint(x: board.canvasFrame(board.title).midX, y: board.canvasFrame(board.title).midY)] }

        board.model.pick(.element(board.body))
        #expect(board.model.selection == CanvasSelection([.element(board.title), .element(board.body)]))
        board.model.pick(.element(board.note))
        #expect(board.model.selection?.things.count == 3)
        // Tapped again, a thing is let go of.
        board.model.pick(.element(board.body))
        #expect(board.model.selection == CanvasSelection([.element(board.title), .element(board.note)]))
    }

    @Test func liftingTheFingerThatRestedIsNotATapOfItsOwn() {
        let board = Board()
        board.model.tool = .select
        board.model.restingFingers = { [CGPoint(x: board.canvasFrame(board.title).midX, y: board.canvasFrame(board.title).midY)] }
        board.model.pick(.element(board.body))
        let both = CanvasSelection([.element(board.title), .element(board.body)])

        // The finger lifts, which reaches the title as a tap.
        board.model.restingFingers = { [] }
        board.model.pick(.element(board.title))
        #expect(board.model.selection == both)

        // A tap after that is a tap.
        board.model.pick(.element(board.title))
        #expect(board.model.selection == .element(board.title))
    }

    @Test func aFingerRestingOnTheScreenAddsElementsWithoutSelectingTheScreen() throws {
        let board = Board()
        board.model.tool = .select
        board.model.selection = .element(board.title)
        // Resting on an empty part of the screen.
        let screen = try #require(board.store.screen(board.screen))
        board.model.restingFingers = { [screen.canvasPoint(for: CGPoint(x: 200, y: 500))] }
        board.model.pick(.element(board.button))
        #expect(board.model.selection == CanvasSelection([.element(board.title), .element(board.button)]))
    }

    @Test func aTapWithNoFingerRestingSelectsOnlyWhatIsTapped() {
        let board = Board()
        board.model.selection = CanvasSelection([.element(board.title), .element(board.body)])
        board.model.pick(.element(board.note))
        #expect(board.model.selection == .element(board.note))
        board.model.pick(nil)
        #expect(board.model.selection == nil)
    }

    @Test func aFingerRestingOnAPanelIsNotRestingOnTheCanvas() {
        let board = Board()
        board.model.selection = .element(board.title)
        board.model.chromeFrames["format"] = CGRect(x: 900, y: 80, width: 300, height: 600)
        board.model.restingFingers = { [CGPoint(x: 1000, y: 300)] }
        board.model.pick(.element(board.body))
        #expect(board.model.selection == .element(board.body))
    }

    @Test func aSettingChangedForSeveralElementsChangesEachThatHasIt() throws {
        let board = Board()
        board.model.selection = CanvasSelection([.element(board.title), .element(board.button), .element(board.note)])
        let red = RGBColor(hex: 0xFF0000)
        board.model.changeSelectedElements(where: \.hasFill) { $0.tint = red }
        // A title has no fill of its own to colour.
        #expect(board.store.resolve(board.button)?.element.tint == red)
        #expect(board.store.resolve(board.note)?.element.tint == red)
        #expect(board.store.resolve(board.title)?.element.tint != red)
    }

    @Test func severalThingsAreLockedCopiedLinedUpAndDeletedTogether() throws {
        let board = Board()
        let selection = try #require(CanvasSelection([.element(board.title), .element(board.note)]))
        board.model.selection = selection

        board.model.setSelectionLocked(true)
        #expect(board.model.isSelectionLocked)
        #expect(board.store.resolve(board.title)?.element.isLocked == true)
        #expect(board.store.resolve(board.note)?.element.isLocked == true)
        board.model.deleteSelection()
        #expect(board.store.resolve(board.title) != nil, "locked things are not deleted")
        board.model.setSelectionLocked(false)
        #expect(!board.model.isSelectionLocked)

        board.model.alignSelection(.left)
        #expect(board.canvasFrame(board.note).minX == board.canvasFrame(board.title).minX)

        board.model.duplicateSelection()
        let copies = try #require(board.model.selection)
        #expect(copies.things.count == 2)
        #expect(copies.things.isDisjoint(with: selection.things))

        board.model.selection = selection
        board.model.deleteSelection()
        #expect(board.store.resolve(board.title) == nil)
        #expect(board.store.resolve(board.note) == nil)
        #expect(board.model.selection == nil)
    }

    @Test func whatHasGoneIsDroppedFromTheSelection() {
        let board = Board()
        board.model.selection = CanvasSelection([.element(board.title), .element(board.body), .element(board.note)])
        board.store.delete(board.note)
        #expect(board.model.selection == CanvasSelection([.element(board.title), .element(board.body)]))
        board.store.delete(board.body)
        #expect(board.model.selection == .element(board.title))
    }

    @Test func hidingOneOfSeveralLetsGoOfThatOne() {
        let board = Board()
        board.model.selection = CanvasSelection([.element(board.title), .element(board.body)])
        board.model.toggleHidden(board.body)
        #expect(board.model.selection == .element(board.title))
    }

    @Test func aBoxDraggedOutSelectsWhatItHoldsAsItGoes() {
        let board = Board()
        let title = board.canvasFrame(board.title), body = board.canvasFrame(board.body)
        let start = CGPoint(x: title.minX - 8, y: title.minY - 8)
        // The view shows the canvas as it is: its points are the canvas's.
        board.model.boxDragged(from: start, to: CGPoint(x: title.maxX + 8, y: title.maxY + 8))
        #expect(board.model.selection == .element(board.title))
        #expect(board.model.sweep != nil)
        board.model.boxDragged(from: start, to: CGPoint(x: body.maxX + 8, y: body.maxY + 8))
        #expect(board.model.selection == CanvasSelection([.element(board.title), .element(board.body)]))
        board.model.sweepEnded()
        #expect(board.model.sweep == nil)
        #expect(board.model.selection?.things.count == 2)
    }

    @Test func aLoopDrawnWithTheLassoSelectsWhenThePenLifts() {
        let board = Board()
        let area = board.canvasFrame(board.note).insetBy(dx: -10, dy: -10)
        board.model.lassoDrawn(loop(round: area))
        #expect(board.model.sweep != nil)
        #expect(board.model.selection == nil, "nothing is picked until the loop is finished")
        board.model.sweepEnded()
        #expect(board.model.sweep == nil)
        #expect(board.model.selection == .element(board.note))
    }

    @Test func aLoopIsReadWhereTheCanvasHasBeenScrolledAndZoomedTo() {
        let board = Board()
        board.model.viewport = Viewport(offset: CGPoint(x: 200, y: 100), scale: 2)
        let area = board.canvasFrame(board.note).insetBy(dx: -10, dy: -10)
        board.model.lassoDrawn(loop(round: area).map(board.model.viewport.viewPoint(for:)))
        board.model.sweepEnded()
        #expect(board.model.selection == .element(board.note))
    }
}
