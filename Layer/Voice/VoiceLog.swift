import OSLog

/// What voice mode writes to the log, so that a call on a real iPad can be followed from
/// a Mac: what was heard, what was done with it, and what went wrong and where.
///
/// What a person says and what is on their design are theirs. Those are logged as
/// private, which shows them to a developer watching the app and to nobody reading the
/// device's log afterwards. Everything else is the bare course of the call: steps, tool
/// names, counts and errors.
enum VoiceLog {
    static let log = Logger(subsystem: "kahshin.Layer", category: "voice")
}
