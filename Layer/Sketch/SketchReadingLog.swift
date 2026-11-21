import CoreGraphics
import Foundation

/// One Magic Pen reading, kept only on this device so the score table's thresholds — and,
/// once there's enough of a corpus, the table itself — can be tuned from how Layer is
/// actually used. `magic-pen-expansion.md` §3G: "Log corrections on the device... nothing
/// needs to leave the device."
///
/// Never uploaded, and nothing here reads it off the device either: it's written to a file
/// under Application Support that's excluded from iCloud backup, for a developer to find
/// and export by hand (`SketchReadingLog.exportAsFixtures`) during development. Stage 0 of
/// `reports/Fast and slow sketch recognition.md`.
struct SketchReadingLogEntry: Codable, Sendable, Identifiable {
    var id: UUID
    var timestamp: Date
    /// "openCanvas" or "onScreen"; matches `SketchFixture.PlacementKind`'s raw values so an
    /// export can be loaded by `SketchFixtureCorpus` unchanged.
    var placementKind: String
    var existingKinds: [String]
    var existingFrames: [[Double]]
    var screenSize: [Double]?
    /// One array of `[x, y]` points per stroke.
    var strokes: [[[Double]]]
    /// The reading's candidates, ranked, named as `SketchPrompt.name(for:)` does.
    var candidates: [String]
    /// Parallel to `candidates`: each one's score from `SketchRequest.scoredReadings`.
    var scores: [Double]
    var chosen: String
    var escalated: Bool
    /// "rules" or a provider id such as "apple-intelligence".
    var decidedBy: String
    /// Set once a correction is observed. There's no "change this element's kind" action
    /// yet, so the available signal is the element being deleted soon after Magic Pen
    /// created it — not the same thing as a correction, but the closest one Layer has.
    var correctedAfter: Double?
    /// What the reading should have been, once the element it became has been changed
    /// into another kind: that kind's raw value, as a benchmark fixture's label is.
    var correctedTo: String?
}

/// Buffers readings in memory and appends them to an on-device log, one process-wide
/// instance so every design shares it. `SketchEngine` writes a reading when it makes one;
/// whoever deletes an element tells `noteDeleted` so a reading that was undone soon after
/// gets marked, without the log needing to know anything about `DesignStore` itself.
actor SketchReadingLog {
    static let shared = SketchReadingLog()

    /// How long after creation a deletion still counts as a likely correction of that
    /// reading, rather than someone tidying up a design much later.
    static let correctionWindow: TimeInterval = 20

    private var entries: [UUID: SketchReadingLogEntry] = [:]
    private var order: [UUID] = []
    /// A reading's log entry, found again by the id of the element it became — the only
    /// link between a reading and whatever later happens to the element it produced.
    private var elementToEntry: [UUID: UUID] = [:]
    private let fileURL: URL?

    init(fileURL: URL? = SketchReadingLog.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("SketchLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent("readings.jsonl")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Logs one reading and returns its entry id, to pass to `link` if it became an element.
    @discardableResult
    func record(
        placementKind: String, existingKinds: [String], existingFrames: [[Double]], screenSize: [Double]?,
        strokes: [[[Double]]], candidates: [String], scores: [Double], chosen: String, escalated: Bool, decidedBy: String
    ) -> UUID {
        let entry = SketchReadingLogEntry(
            id: UUID(), timestamp: .now, placementKind: placementKind, existingKinds: existingKinds,
            existingFrames: existingFrames, screenSize: screenSize, strokes: strokes, candidates: candidates,
            scores: scores, chosen: chosen, escalated: escalated, decidedBy: decidedBy, correctedAfter: nil, correctedTo: nil
        )
        entries[entry.id] = entry
        order.append(entry.id)
        append(entry)
        return entry.id
    }

    /// Call once the element a reading became exists, so a later deletion can find its way
    /// back to the reading that produced it.
    func link(element elementID: UUID, toEntry entryID: UUID) {
        elementToEntry[elementID] = entryID
    }

    /// Call whenever an element is deleted. A no-op for most deletions, since most elements
    /// were never a Magic Pen reading, or this one's correction window has already passed.
    func noteDeleted(_ elementID: UUID) {
        guard let entryID = elementToEntry.removeValue(forKey: elementID), var entry = entries[entryID], entry.correctedAfter == nil else { return }
        let elapsed = Date.now.timeIntervalSince(entry.timestamp)
        guard elapsed <= Self.correctionWindow else { return }
        entry.correctedAfter = elapsed
        entries[entryID] = entry
        rewrite()
    }

    /// Call when the element a reading became is changed into another kind, which says
    /// what the reading should have been. A no-op for elements that were never a reading.
    func noteCorrected(_ elementID: UUID, to kind: String) {
        guard let entryID = elementToEntry[elementID], var entry = entries[entryID] else { return }
        entry.correctedTo = kind
        entries[entryID] = entry
        rewrite()
    }

    /// Every logged reading, oldest first.
    func allEntries() -> [SketchReadingLogEntry] {
        order.compactMap { entries[$0] }
    }

    /// Writes every logged reading as its own fixture-shaped JSON file, in the field
    /// layout `SketchFixtureCorpus.load` reads, so they can be copied into
    /// `LayerTests/Fixtures` directly. A reading that was corrected is labelled with what
    /// it was corrected to. What the others should have been isn't known here: they are
    /// labelled "unknown" and `variant: confusable`, a placeholder for a person to correct
    /// by hand before it's added to the real corpus.
    func exportAsFixtures(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in allEntries() {
            let existing = zip(entry.existingKinds, entry.existingFrames).map { ["kind": $0, "frame": $1] as [String: Any] }
            let object: [String: Any] = [
                "id": entry.id.uuidString,
                "label": entry.correctedTo ?? "unknown",
                "variant": "confusable",
                "placementKind": entry.placementKind,
                "existing": existing,
                "screenSize": entry.screenSize as Any,
                "strokes": entry.strokes,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("\(entry.id.uuidString).json"))
        }
    }

    /// Appends one entry as a line of JSON. Correcting an existing entry later requires
    /// rewriting the file (`rewrite`); a fresh reading never does.
    private func append(_ entry: SketchReadingLogEntry) {
        guard let fileURL, let data = try? JSONEncoder().encode(entry), let line = String(data: data, encoding: .utf8) else { return }
        let lineData = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            // The throwing calls: the older ones raise an exception nothing can catch when
            // the disk is full.
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: fileURL)
        }
    }

    /// Rewrites the log so a correction recorded after the fact is reflected. The file
    /// holds every launch's readings and this launch knows only its own, so only the lines
    /// of readings known here are written anew; the rest are kept as they are. The log is
    /// one person's on-device history of Magic Pen readings, so this stays small enough
    /// that rewriting it on every correction is cheap.
    private func rewrite() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        func line(for entry: SketchReadingLogEntry) -> String? {
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        struct Identified: Decodable { var id: UUID }
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        var written: Set<UUID> = []
        var lines = existing.map { existingLine -> String in
            guard let id = try? JSONDecoder().decode(Identified.self, from: Data(existingLine.utf8)).id,
                  let entry = entries[id], let updated = line(for: entry) else { return existingLine }
            written.insert(id)
            return updated
        }
        // A reading whose line never reached the file goes on the end.
        lines += order.filter { !written.contains($0) }.compactMap { entries[$0] }.compactMap(line(for:))
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
