import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Tidying a screen's layout")
struct ScreenTidyTests {
    private func element(_ kind: ElementKind, _ frame: CGRect, text: String = "") -> DesignElement {
        var element = DesignStore.newElement(kind)
        element.frame = frame
        if !text.isEmpty { element.text = text }
        return element
    }

    /// A rough phone screen: a title, its body, two fields, a checkbox beside its label,
    /// and a button near the bottom, all a little off.
    private func messy() -> [DesignElement] {
        [
            element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Sign up"),
            element(.body, CGRect(x: 30, y: 170, width: 300, height: 44)),
            element(.textField, CGRect(x: 10, y: 260, width: 250, height: 48), text: "Email"),
            element(.textField, CGRect(x: 35, y: 330, width: 333, height: 48), text: "Password"),
            element(.checkbox, CGRect(x: 30, y: 410, width: 24, height: 24)),
            element(.text, CGRect(x: 70, y: 408, width: 200, height: 24), text: "I agree"),
            element(.button, CGRect(x: 40, y: 770, width: 300, height: 50), text: "Create account"),
        ]
    }

    private func expectNoOverlaps(_ frames: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, one) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) {
                #expect(!one.intersects(other), "\(one) overlaps \(other)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func keepsTheOrderAndTheRows() throws {
        let elements = messy()
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        #expect(frames.count == elements.count)
        let tidied = elements.map { frames[$0.id]! }
        // Top to bottom as before, the checkbox and its label still side by side.
        let column = [0, 1, 2, 3, 4, 6].map { tidied[$0].minY }
        #expect(column == column.sorted())
        #expect(abs(tidied[4].midY - tidied[5].midY) < 1)
        #expect(tidied[4].maxX < tidied[5].minX)
        expectNoOverlaps(tidied)
    }

    @Test func everythingIsOnOneMarginAndOnTheRhythm() throws {
        let elements = messy()
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let tidied = elements.map { frames[$0.id]! }
        // Full width for the title, body, fields and button: 20 points in from each side.
        for index in [0, 1, 2, 3, 6] {
            #expect(tidied[index].minX == 20)
            #expect(tidied[index].width == 353)
        }
        // The checkbox keeps its size, at the margin; its label takes the rest of the row.
        #expect(tidied[4].size == CGSize(width: 24, height: 24))
        #expect(tidied[4].minX == 20)
        #expect(tidied[5].maxX == 373)
        // The first row is where the generator puts it; the body sits close under the title.
        #expect(tidied[0].minY == DeviceFrame.iPhone.safeTop + 16)
        #expect(tidied[1].minY - tidied[0].maxY == ScreenTidy.tight)
        #expect(tidied[3].minY - tidied[2].maxY == ScreenTidy.normal)
    }

    @Test func aButtonNearTheBottomStaysPinnedThere() throws {
        let elements = messy()
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let button = try #require(frames[elements[6].id])
        #expect(button.maxY == DeviceFrame.iPhone.size.height - ScreenTidy.bottomInset(on: .iPhone))
    }

    @Test func lockedHiddenAndDrawnThingsStayPut() throws {
        var locked = element(.image, CGRect(x: 20, y: 200, width: 353, height: 150))
        locked.isLocked = true
        var hidden = element(.body, CGRect(x: 5, y: 5, width: 100, height: 44))
        hidden.isHidden = true
        let shape = element(.shape, CGRect(x: 300, y: 600, width: 50, height: 50))
        let others = [
            element(.title, CGRect(x: 40, y: 90, width: 228, height: 40)),
            element(.textField, CGRect(x: 40, y: 380, width: 200, height: 48)),
            element(.textField, CGRect(x: 40, y: 450, width: 200, height: 48)),
        ]
        let frames = ScreenTidy.frames(for: [locked, hidden, shape] + others, on: .iPhone)
        #expect(frames[locked.id] == nil && frames[hidden.id] == nil && frames[shape.id] == nil)
        // The rest go round the locked image, in the order they were in.
        let tidied = others.map { frames[$0.id]! }
        for frame in tidied { #expect(!frame.intersects(locked.frame)) }
        #expect(tidied[0].maxY <= locked.frame.minY)
        #expect(tidied[1].minY >= locked.frame.maxY)
        #expect(tidied[1].minY < tidied[2].minY)
    }

    /// Too much for the usual spacing: the gaps close up before the button lets go of the bottom.
    @Test func itFitsOnTheScreen() throws {
        var elements = [element(.title, CGRect(x: 20, y: 75, width: 353, height: 40))]
        for index in 0..<10 {
            elements.append(element(.textField, CGRect(x: 20, y: 130 + CGFloat(index) * 52, width: 353, height: 50)))
        }
        let button = element(.button, CGRect(x: 20, y: 760, width: 353, height: 50))
        elements.append(button)
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let tidied = elements.map { frames[$0.id]! }
        expectNoOverlaps(tidied)
        for frame in tidied { #expect(frame.maxY <= DeviceFrame.iPhone.size.height) }
        #expect(frames[button.id]!.maxY == DeviceFrame.iPhone.size.height - ScreenTidy.bottomInset(on: .iPhone))
    }

    /// A row pinned to the bottom goes above a locked element there, rather than onto it
    /// (audit M7): a primary button above a locked footer picture was set down on the picture.
    @Test func aPinnedRowStaysClearOfALockedElementAtTheBottom() throws {
        var footer = element(.image, CGRect(x: 20, y: 760, width: 353, height: 60))
        footer.isLocked = true
        let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Welcome")
        let button = element(.button, CGRect(x: 20, y: 700, width: 353, height: 50), text: "Continue")
        let frames = ScreenTidy.frames(for: [footer, title, button], on: .iPhone)
        let pinned = try #require(frames[button.id])
        #expect(!pinned.intersects(footer.frame), "\(pinned) is on the locked picture")
        #expect(pinned.maxY <= footer.frame.minY)
        // Still at the bottom: just above the picture, not let go to follow the title.
        #expect(pinned.maxY == footer.frame.minY - ScreenTidy.normal)
    }

    /// The same for a card with something on it, which the layout keeps clear.
    @Test func aPinnedRowStaysClearOfACardAtTheBottom() throws {
        let card = element(.shape, CGRect(x: 20, y: 740, width: 353, height: 80))
        let label = element(.text, CGRect(x: 40, y: 760, width: 200, height: 30), text: "Card")
        let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Welcome")
        let button = element(.button, CGRect(x: 20, y: 680, width: 353, height: 50), text: "Continue")
        let frames = ScreenTidy.frames(for: [card, label, title, button], on: .iPhone)
        let pinned = try #require(frames[button.id])
        #expect(!pinned.intersects(card.frame), "\(pinned) is on the card")
    }

    /// Pinned rows pushed up past what flows above them aren't pinned: the rows flow instead.
    @Test func pinnedRowsThatCantClearLetGo() throws {
        var wall = element(.image, CGRect(x: 0, y: 200, width: 393, height: 600))
        wall.isLocked = true
        let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Welcome")
        let button = element(.button, CGRect(x: 20, y: 810, width: 353, height: 30), text: "Continue")
        let frames = ScreenTidy.frames(for: [wall, title, button], on: .iPhone)
        let tidied = [title, button].map { frames[$0.id]! }
        for frame in tidied { #expect(!frame.intersects(wall.frame), "\(frame) is on the locked picture") }
        expectNoOverlaps(tidied)
    }

    @Test func aRowOfSmallThingsGetsEqualSlots() throws {
        let icons = (0..<4).map { element(.symbol, CGRect(x: 40 + CGFloat($0) * 60, y: 300, width: 44, height: 44)) }
        let frames = ScreenTidy.frames(for: icons, on: .iPhone)
        let tidied = icons.map { frames[$0.id]! }
        let slot = 353.0 / 4
        for (index, frame) in tidied.enumerated() {
            #expect(abs(frame.midX - (20 + slot * (Double(index) + 0.5))) <= 1)
            #expect(frame.size == CGSize(width: 44, height: 44))
        }
    }

    @Test func aNewDeviceGetsALayoutOfItsOwn() throws {
        let elements = messy()
        guard let iPad = DeviceFrame.all.first(where: { $0.id == "ipad" }) else { throw CancellationError() }
        let frames = ScreenTidy.frames(for: elements, on: iPad, from: .iPhone)
        let tidied = elements.map { frames[$0.id]! }
        let bounds = CGRect(origin: .zero, size: iPad.size)
        for frame in tidied { #expect(bounds.contains(frame)) }
        let column = ScreenTidy.column(on: iPad)
        // Full-width things span the iPad's column, not a phone's width.
        for index in [1, 2, 3, 6] {
            #expect(tidied[index].minX == column.x)
            #expect(tidied[index].width == column.width)
        }
        #expect(tidied[6].maxY == iPad.size.height - ScreenTidy.bottomInset(on: iPad))
        expectNoOverlaps(tidied)
    }

    private func iPad() throws -> DeviceFrame {
        try #require(DeviceFrame.all.first { $0.id == "ipad" })
    }

    /// A phone's 353 × 200 image kept its height on an iPad and became a flat strip.
    @Test func anImageKeepsItsShapeOnANewDevice() throws {
        let iPad = try iPad()
        let image = element(.image, CGRect(x: 20, y: 120, width: 353, height: 200))
        let elements = [element(.title, CGRect(x: 20, y: 70, width: 353, height: 40)), image]
        let frame = try #require(ScreenTidy.frames(for: elements, on: iPad, from: .iPhone)[image.id])
        #expect(frame.width == ScreenTidy.column(on: iPad).width)
        #expect(abs(frame.height - (200 * frame.width / 353).rounded()) <= 1)
        // Tidied where it is, a narrow image widened to the column grows with it too.
        let narrow = element(.image, CGRect(x: 30, y: 120, width: 300, height: 150))
        let tidied = try #require(ScreenTidy.frames(for: [narrow], on: .iPhone)[narrow.id])
        #expect(tidied.size == CGSize(width: 353, height: 177))
    }

    /// A tall picture grows no taller than half the screen, and the rest still fits.
    @Test func aTallImageIsHeldToHalfTheScreen() throws {
        let iPad = try iPad()
        let image = element(.image, CGRect(x: 20, y: 120, width: 353, height: 400))
        let elements = [
            element(.title, CGRect(x: 20, y: 70, width: 353, height: 40)),
            image,
            element(.textField, CGRect(x: 20, y: 540, width: 353, height: 48)),
            element(.textField, CGRect(x: 20, y: 600, width: 353, height: 48)),
            element(.button, CGRect(x: 20, y: 770, width: 353, height: 50)),
        ]
        let frames = ScreenTidy.frames(for: elements, on: iPad, from: .iPhone)
        let held = try #require(frames[image.id])
        #expect(held.height == iPad.size.height / 2)
        // The width follows the height, so the picture isn't stretched, and it is centred.
        #expect(abs(held.width / held.height - 353.0 / 400.0) < 0.01)
        let column = ScreenTidy.column(on: iPad)
        #expect(abs(held.midX - (column.x + column.width / 2)) <= 1)
        let tidied = elements.map { frames[$0.id]! }
        let bounds = CGRect(origin: .zero, size: iPad.size)
        for frame in tidied { #expect(bounds.contains(frame)) }
        expectNoOverlaps(tidied)
    }

    /// A caption laid on a photo on purpose stays on it, in the same place, on this device
    /// and on another; the photo and its caption are one block in the layout.
    @Test func aCaptionOnAnImageRidesWithIt() throws {
        let image = element(.image, CGRect(x: 20, y: 140, width: 353, height: 200))
        let caption = element(.text, CGRect(x: 36, y: 290, width: 200, height: 34), text: "Summer sale")
        let button = element(.button, CGRect(x: 140, y: 180, width: 100, height: 40), text: "Shop")
        let others = [
            element(.title, CGRect(x: 30, y: 80, width: 300, height: 40), text: "Shop"),
            element(.body, CGRect(x: 25, y: 370, width: 330, height: 44)),
        ]
        let elements = [others[0], image, caption, button, others[1]]
        for (device, previous) in [(DeviceFrame.iPhone, DeviceFrame.iPhone), (try iPad(), .iPhone)] {
            let frames = ScreenTidy.frames(for: elements, on: device, from: previous)
            let photo = try #require(frames[image.id])
            for rider in [caption, button] {
                let frame = try #require(frames[rider.id])
                #expect(photo.contains(frame), "\(rider.text) stays on the photo")
                // In the same place on it.
                let before = ((rider.frame.midX - image.frame.minX) / image.frame.width, (rider.frame.midY - image.frame.minY) / image.frame.height)
                let after = ((frame.midX - photo.minX) / photo.width, (frame.midY - photo.minY) / photo.height)
                #expect(abs(before.0 - after.0) < 0.02 && abs(before.1 - after.1) < 0.02)
                #expect(frame.height == rider.frame.height, "text keeps its height")
            }
            // The rest go round the block, in order.
            let laid = [others[0], image, others[1]].map { frames[$0.id]! }
            expectNoOverlaps(laid)
            #expect(laid[0].maxY <= laid[1].minY && laid[1].maxY <= laid[2].minY)
        }
    }

    /// Text that only strays over the edge of a picture overlaps it by accident, and is
    /// moved off it.
    @Test func anAccidentalOverlapIsStillSeparated() throws {
        let image = element(.image, CGRect(x: 20, y: 140, width: 353, height: 200))
        // Half of it over the photo's bottom edge.
        let text = element(.text, CGRect(x: 40, y: 320, width: 250, height: 40), text: "Caption")
        let frames = ScreenTidy.frames(for: [image, text], on: .iPhone)
        let photo = try #require(frames[image.id])
        let moved = try #require(frames[text.id])
        #expect(!photo.intersects(moved))
        #expect(moved.minY > photo.maxY)
    }

    /// Text on a shape stays with the shape, which is the person's own and stays put.
    @Test func whatRidesOnAShapeStaysWithIt() throws {
        let card = element(.shape, CGRect(x: 20, y: 500, width: 353, height: 120))
        let label = element(.text, CGRect(x: 40, y: 540, width: 200, height: 30), text: "Card")
        let title = element(.title, CGRect(x: 40, y: 90, width: 228, height: 40))
        let frames = ScreenTidy.frames(for: [card, label, title], on: .iPhone)
        #expect(frames[card.id] == nil && frames[label.id] == nil)
        #expect(frames[title.id] != nil)
    }

    /// A background that fills the screen is not a card: nothing is laid on it, so the
    /// title and the button on top of it are tidied as usual and the background stays.
    @Test func aFullScreenBackgroundIsNotAHost() throws {
        for kind in [ElementKind.shape, .image] {
            let background = element(kind, CGRect(x: 0, y: 0, width: 393, height: 852))
            let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Hello")
            let button = element(.button, CGRect(x: 40, y: 300, width: 300, height: 50), text: "Go")
            let frames = ScreenTidy.frames(for: [background, title, button], on: .iPhone)
            let margin = ScreenTidy.margin(on: .iPhone)
            #expect(frames[background.id] == nil, "\(kind)")
            #expect(frames[title.id]?.minX == margin, "\(kind)")
            #expect(frames[button.id]?.minX == margin, "\(kind)")
            #expect(frames[button.id]?.width == 393 - margin * 2, "\(kind)")
        }
    }

    /// A card with a label on it is kept clear: what is laid out round it doesn't land on it.
    @Test func whatIsLaidOutKeepsClearOfACard() throws {
        let card = element(.shape, CGRect(x: 20, y: 300, width: 353, height: 200))
        let label = element(.text, CGRect(x: 40, y: 340, width: 200, height: 30), text: "Card")
        let others = [
            element(.title, CGRect(x: 20, y: 90, width: 300, height: 40), text: "Title"),
            element(.body, CGRect(x: 20, y: 150, width: 300, height: 44)),
            element(.textField, CGRect(x: 20, y: 230, width: 353, height: 48), text: "A"),
            element(.textField, CGRect(x: 20, y: 530, width: 353, height: 48), text: "B"),
            element(.textField, CGRect(x: 20, y: 600, width: 353, height: 48), text: "C"),
            element(.textField, CGRect(x: 20, y: 670, width: 353, height: 48), text: "D"),
        ]
        let frames = ScreenTidy.frames(for: [card, label] + others, on: .iPhone)
        #expect(frames[card.id] == nil && frames[label.id] == nil)
        for other in others {
            let frame = try #require(frames[other.id])
            #expect(!frame.intersects(card.frame), "\(frame) is on the card")
        }
    }

    /// What is laid on a locked picture stays where it is, with the picture.
    @Test func whatRidesOnALockedPictureStaysPut() throws {
        var image = element(.image, CGRect(x: 20, y: 300, width: 353, height: 200))
        image.isLocked = true
        let caption = element(.text, CGRect(x: 40, y: 450, width: 200, height: 30), text: "Caption")
        let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40))
        let frames = ScreenTidy.frames(for: [image, caption, title], on: .iPhone)
        #expect(frames[image.id] == nil && frames[caption.id] == nil)
        #expect(frames[title.id] != nil)
    }

    /// A locked picture that covers much of the screen, but not all, is still in the way.
    @Test func aLockedHeroPictureIsKeptClear() throws {
        var hero = element(.image, CGRect(x: 0, y: 100, width: 393, height: 500))
        hero.isLocked = true
        let others = [
            element(.title, CGRect(x: 20, y: 60, width: 300, height: 30), text: "Title"),
            element(.textField, CGRect(x: 20, y: 620, width: 353, height: 48), text: "A"),
            element(.textField, CGRect(x: 20, y: 690, width: 353, height: 48), text: "B"),
            element(.button, CGRect(x: 20, y: 760, width: 353, height: 50), text: "Go"),
        ]
        let frames = ScreenTidy.frames(for: [hero] + others, on: .iPhone)
        #expect(frames[hero.id] == nil)
        for other in others {
            let frame = try #require(frames[other.id])
            #expect(!frame.intersects(hero.frame), "\(frame) is on the hero")
        }
    }

    /// A locked background that fills the screen is no obstacle: the rest is still tidied.
    @Test func aLockedFullScreenBackgroundIsNotAnObstacle() throws {
        var background = element(.image, CGRect(x: 0, y: 0, width: 393, height: 852))
        background.isLocked = true
        let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Hello")
        let button = element(.button, CGRect(x: 40, y: 300, width: 300, height: 50), text: "Go")
        let frames = ScreenTidy.frames(for: [background, title, button], on: .iPhone)
        #expect(frames[background.id] == nil)
        #expect(frames[title.id]?.minX == ScreenTidy.margin(on: .iPhone))
        #expect(frames[button.id]?.minX == ScreenTidy.margin(on: .iPhone))
    }

    /// A background grows with its screen when the device changes; a locked one stays.
    @Test func aBackgroundFillsTheNewDevice() throws {
        let iPad = try iPad()
        let background = element(.shape, CGRect(x: 0, y: 0, width: 393, height: 852))
        let title = element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Hello")
        let frames = ScreenTidy.frames(for: [background, title], on: iPad, from: .iPhone)
        #expect(frames[background.id] == CGRect(origin: .zero, size: iPad.size))
        var locked = background
        locked.isLocked = true
        #expect(ScreenTidy.frames(for: [locked, title], on: iPad, from: .iPhone)[locked.id] == nil)
    }

    /// A big picture that doesn't cover the screen is laid out like any other, and the rest
    /// of the screen doesn't flow over it.
    @Test func anUnlockedHeroPictureIsLaidOutAndKeptClear() throws {
        let hero = element(.image, CGRect(x: 0, y: 100, width: 393, height: 500))
        let others = [
            element(.title, CGRect(x: 20, y: 60, width: 300, height: 30), text: "Title"),
            element(.textField, CGRect(x: 20, y: 620, width: 353, height: 48), text: "A"),
            element(.textField, CGRect(x: 20, y: 690, width: 353, height: 48), text: "B"),
            element(.button, CGRect(x: 20, y: 760, width: 353, height: 50), text: "Go"),
        ]
        let frames = ScreenTidy.frames(for: [hero] + others, on: .iPhone)
        let laid = [hero] + others
        let tidied = try laid.map { try #require(frames[$0.id]) }
        expectNoOverlaps(tidied)
    }

    // MARK: Turned elements

    private func turned(_ element: DesignElement, by degrees: Double) -> DesignElement {
        var element = element
        element.setRotation(degrees)
        return element
    }

    /// The box a turned element takes up where the tidy put it.
    private func box(of element: DesignElement, at frame: CGRect) -> CGRect {
        var placed = element
        placed.frame = frame
        return placed.shapeBounds
    }

    /// A button turned 15° stands about 140 points tall: the tidy lays out that box, so the
    /// rows round it keep clear of it, rather than giving it a row 50 points tall.
    @Test func nothingIsLaidOverATurnedButton() throws {
        let button = turned(element(.button, CGRect(x: 20, y: 330, width: 353, height: 50), text: "Go"), by: 15)
        let elements = [
            element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Sign up"),
            element(.body, CGRect(x: 30, y: 170, width: 300, height: 44)),
            element(.textField, CGRect(x: 10, y: 260, width: 250, height: 48), text: "Email"),
            button,
            element(.textField, CGRect(x: 35, y: 420, width: 333, height: 48), text: "Password"),
            element(.textField, CGRect(x: 35, y: 490, width: 333, height: 48), text: "Code"),
        ]
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let frame = try #require(frames[button.id])
        #expect(frame.size == button.frame.size, "a turned element keeps its size")
        let box = box(of: button, at: frame)
        for other in elements where other.id != button.id {
            let laid = try #require(frames[other.id])
            #expect(!laid.intersects(box), "\(laid) is laid over the turned button's \(box)")
        }
        // In its place in the order, and on the screen.
        #expect(try #require(frames[elements[2].id]).maxY <= box.minY)
        #expect(box.maxY <= (try #require(frames[elements[4].id])).minY)
        #expect(CGRect(origin: .zero, size: DeviceFrame.iPhone.size).contains(box))
    }

    /// Stood on end on a phone, a button moved to an iPad keeps its size: stretched to the
    /// iPad's column it was 756 points long, and stood on end ran off the top of the screen.
    @Test func aQuarterTurnedButtonKeepsItsSizeOnANewDevice() throws {
        let iPad = try iPad()
        let button = turned(element(.button, CGRect(x: 20, y: 300, width: 353, height: 50), text: "Go"), by: 90)
        let elements = [
            element(.title, CGRect(x: 20, y: 70, width: 353, height: 40), text: "Title"),
            button,
            element(.textField, CGRect(x: 20, y: 520, width: 353, height: 48), text: "A"),
        ]
        let frames = ScreenTidy.frames(for: elements, on: iPad, from: .iPhone)
        let frame = try #require(frames[button.id])
        #expect(frame.size == button.frame.size)
        let box = box(of: button, at: frame)
        #expect(CGRect(origin: .zero, size: iPad.size).contains(box), "\(box) is off the screen")
        for other in elements where other.id != button.id {
            #expect(!(try #require(frames[other.id])).intersects(box))
        }
    }

    /// A turned picture isn't widened to the column either: it keeps its size, so it can't
    /// grow taller than half the screen on its end.
    @Test func aTurnedPictureKeepsItsSize() throws {
        let iPad = try iPad()
        let image = turned(element(.image, CGRect(x: 20, y: 200, width: 353, height: 200)), by: 90)
        let title = element(.title, CGRect(x: 20, y: 70, width: 353, height: 40), text: "Title")
        let frames = ScreenTidy.frames(for: [title, image], on: iPad, from: .iPhone)
        let frame = try #require(frames[image.id])
        #expect(frame.size == image.frame.size)
        let box = box(of: image, at: frame)
        #expect(box.height <= iPad.size.height / 2)
        #expect(!(try #require(frames[title.id])).intersects(box))
    }

    /// A turned caption on a photo goes with the photo as it grows, in the same place on it,
    /// at its own size.
    @Test func aTurnedCaptionRidesOnItsPhotoAtItsOwnSize() throws {
        let iPad = try iPad()
        let image = element(.image, CGRect(x: 20, y: 140, width: 353, height: 200))
        let caption = turned(element(.text, CGRect(x: 60, y: 260, width: 160, height: 30), text: "Sale"), by: 10)
        let title = element(.title, CGRect(x: 30, y: 80, width: 300, height: 40), text: "Shop")
        let frames = ScreenTidy.frames(for: [title, image, caption], on: iPad, from: .iPhone)
        let photo = try #require(frames[image.id])
        let frame = try #require(frames[caption.id])
        #expect(frame.size == caption.frame.size)
        #expect(photo.contains(box(of: caption, at: frame)))
        let before = ((caption.frame.midX - image.frame.minX) / image.frame.width, (caption.frame.midY - image.frame.minY) / image.frame.height)
        let after = ((frame.midX - photo.minX) / photo.width, (frame.midY - photo.minY) / photo.height)
        #expect(abs(before.0 - after.0) < 0.02 && abs(before.1 - after.1) < 0.02)
    }

    @Test func aMacKeepsAReadableColumn() throws {
        guard let mac = DeviceFrame.all.first(where: { $0.id == "imac" }) else { throw CancellationError() }
        let column = ScreenTidy.column(on: mac)
        #expect(column.width == ScreenTidy.widestColumn)
        #expect(column.x == (mac.size.width - column.width) / 2)
    }
}

@Suite("Spoken screen layout and device")
@MainActor
struct VoiceScreenLayoutTests {
    private struct Bench {
        var app: AppModel
        var screen: DesignScreen.ID
        var handles: VoiceHandles
        var box: VoiceToolbox
    }

    private func bench() -> Bench {
        let (app, screen) = VoiceFixture.undoableLogin()
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: app, handles: handles)
        return Bench(app: app, screen: screen, handles: handles, box: VoiceToolbox(model: app, handles: handles))
    }

    @Test func deviceWordsNameDevices() {
        func id(_ words: String, _ usual: DeviceFrame = .iPhone) -> String? { VoiceToolbox.device(named: words, preferring: usual)?.id }
        #expect(id("iPhone") == "iphone")
        #expect(id("phone") == "iphone")
        #expect(id("iPhone Pro Max") == "iphone-pro-max")
        #expect(id("iPhone SE") == "iphone-se")
        #expect(id("iPad") == "ipad")
        #expect(id("an iPad screen") == "ipad")
        #expect(id("tablet") == "ipad")
        #expect(id("iPad mini") == "ipad-mini")
        #expect(id("iPad Pro") == "ipad-pro-13")
        #expect(id("MacBook") == "macbook-air")
        #expect(id("MacBook Pro") == "macbook-pro-16")
        #expect(id("iMac") == "imac")
        #expect(id("desktop") == "macbook-air")
        #expect(id("laptop") == "macbook-air")
        #expect(id("web") == "macbook-air")
        #expect(id("webpage") == "macbook-air")
        #expect(id("a web page") == "macbook-air")
        #expect(id("website") == "macbook-air")
        #expect(id("watch") == nil)
        // A family's word keeps the design's own device of that family.
        let mini = DeviceFrame.all.first { $0.id == "ipad-mini" }!
        #expect(id("iPad", mini) == "ipad-mini")
        #expect(id("phone", mini) == "iphone")
    }

    @Test func thePillSaysWhatTheNewToolsAreDoing() {
        #expect(VoiceTools.step(for: "tidyScreen") == "Tidying…")
        #expect(VoiceTools.step(for: "changeScreenDevice") == "Changing the device…")
    }

    @Test func tidyingLaysTheScreenOutAsOneUndoStep() throws {
        let bench = bench()
        let undo = try #require(bench.app.store.undoManager)
        let before = bench.app.store.content
        let line = bench.box.tidyScreen(screen: "S1")
        #expect(line == "Tidied the layout of S1.")
        let screen = try #require(bench.app.store.screen(bench.screen))
        // The button and the image move up under the title, on the margin.
        let frames = screen.elements.sorted { $0.frame.minY < $1.frame.minY }.map(\.frame)
        #expect(frames.allSatisfy { $0.minX == 20 && $0.width == 353 })
        #expect(frames[1].minY - frames[0].maxY == ScreenTidy.afterHeading)
        undo.undo()
        #expect(bench.app.store.content == before)
    }

    /// Pointed at an element, "this screen" is the screen it is on, with or without its handle.
    @Test func thisScreenIsTheOnePointedAt() throws {
        let bench = bench()
        _ = bench.app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 9000, y: 9000), scale: 0.6))
        let button = try #require(bench.app.store.screen(bench.screen)?.elements.first { $0.kind == .button })
        bench.app.selection = .element(.init(host: .screen(bench.screen), element: button.id))
        #expect(bench.box.tidyScreen(screen: nil) == "Tidied the layout of S1.")
        #expect(bench.box.changeScreenDevice(screen: "E2", device: "iPad").hasPrefix("Made S1 an iPad screen"))
        #expect(bench.app.store.screen(bench.screen)?.deviceID == "ipad")
        #expect(bench.box.tidyScreen(screen: "E99") == "There is no E99.")
    }

    @Test func changingTheDeviceReflowsTheScreen() throws {
        let bench = bench()
        let line = bench.box.changeScreenDevice(screen: "S1", device: "iPad")
        #expect(line == "Made S1 an iPad screen (820 × 1180).")
        let screen = try #require(bench.app.store.screen(bench.screen))
        #expect(screen.deviceID == "ipad")
        let bounds = CGRect(origin: .zero, size: screen.size)
        let column = ScreenTidy.column(on: screen.device)
        for element in screen.elements {
            #expect(bounds.contains(element.frame))
            if element.kind == .image {
                // Held to half the screen's height, so narrower than the column, in its shape.
                #expect(element.frame.width <= column.width)
                #expect(abs(element.frame.width - element.frame.height) <= 1)
            } else {
                #expect(element.frame.width == column.width)
            }
        }
        // Back to an iPhone is no device at all, as the Siri action keeps it.
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "iPhone").hasPrefix("Made S1 an iPhone screen"))
        #expect(bench.app.store.screen(bench.screen)?.deviceID == nil)
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "watch").hasPrefix("I can make it"))
    }

    /// A button stood on end keeps its angle and its size on an iPad, and stays on the screen.
    @Test func aTurnedElementKeepsItsAngleAndSizeOnANewDevice() throws {
        let bench = bench()
        let button = try #require(bench.app.store.screen(bench.screen)?.elements.first { $0.kind == .button })
        let ref = DesignStore.ElementRef(host: .screen(bench.screen), element: button.id)
        bench.app.store.update(ref) { $0.setRotation(90) }
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "iPad").hasPrefix("Made S1 an iPad screen"))
        let screen = try #require(bench.app.store.screen(bench.screen))
        let after = try #require(screen.elements.first { $0.id == button.id })
        #expect(after.rotation == 90)
        #expect(after.frame.size == button.frame.size)
        #expect(CGRect(origin: .zero, size: screen.size).contains(after.shapeBounds))
    }

    @Test func aNewScreenIsOnTheDeviceAskedFor() async throws {
        for (said, expected) in [("iPad", "ipad"), ("webpage", "macbook-air"), (nil, nil) as (String?, String?)] {
            let bench = bench()
            let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
            bench.app.screenStream = { _, _, _ in stream }
            let making = Task { try await bench.box.createScreen(name: "Shop", description: "an Apple product page", device: said) }
            #expect(await eventually { bench.app.isGenerating })
            let made = try #require(bench.app.store.screens.last)
            #expect(made.id != bench.screen)
            #expect(made.deviceID == expected)
            feed.finish()
            _ = try await making.value
        }
    }
}
