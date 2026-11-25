import CoreGraphics
import Foundation

/// Voice's undo and redo, and what a correction ("No, …") may take back with them.
extension VoiceToolbox {
    // MARK: History and the call

    func undo() -> String {
        stepThroughHistory(isUndo: true)
    }

    func redo() -> String {
        stepThroughHistory(isUndo: false)
    }

    /// Undo and redo act on whole steps. What the command has done so far is a step
    /// already, and the command goes on in a new one afterwards: the store sees to both.
    private func stepThroughHistory(isUndo: Bool) -> String {
        guard let model else { return gone }
        guard let history = model.store.undoManager, isUndo ? history.canUndo : history.canRedo else {
            return failed(isUndo ? "There is nothing to undo." : "There is nothing to redo.")
        }
        // "Undo" said outright is the Undo button: the last change goes, whoever made it. A
        // correction ("No, …") is about the command, and takes back only a command's step:
        // a model asked to correct a command undid the person's own change instead (I-2).
        // Nor does a correction redo a change made by hand.
        let isCorrection = spokenCommand.flatMap(VoiceAgent.correction(in:)) != nil
        if isCorrection, correctionUndo == .alreadyDone { return noted(Self.undoneAlready) }
        guard !isCorrection || (isUndo ? model.store.lastStepIsCommand : model.store.nextRedoIsCommand) else {
            return failed(Self.changedByHand)
        }
        guard !isCorrection || correctionUndo == .allowed else { return failed(Self.notThisScreens) }
        if isUndo { history.undo() } else { history.redo() }
        return done(isUndo ? "Undid the last change." : "Redid the last change.")
    }

    /// Why a correction won't undo or redo the change at hand.
    static let changedByHand = "That change was made by hand, not by voice, so a correction leaves it. The Undo and Redo buttons work on it."

    /// What the model is told of an undo or redo asked for in a correction for one screen
    /// whose last change has been undone already.
    static let undoneAlready = "The last change made for this screen has been undone already, so nothing more is undone."

    /// Why a correction for one screen won't undo the change at hand: one made otherwise.
    static let notThisScreens = "A correction for one screen undoes only the last change made for it, so this one stays. The Undo button works on it."

    /// A correction with nothing of the last command's to undo: the command changed
    /// nothing, or something has been changed by hand since, which isn't undone in its place.
    /// `notThisScreens` when it is for one screen, and the last command's step is on top but
    /// wasn't a change to that screen.
    func refuseCorrection(notThisScreens: Bool = false) -> String {
        if notThisScreens { return failed(Self.notThisScreens) }
        return failed("There's nothing of the last command's to undo: it changed nothing, or something has been changed by hand since.")
    }
}
