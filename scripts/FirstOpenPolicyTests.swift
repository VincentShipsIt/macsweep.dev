import Foundation

@main
struct FirstOpenPolicyTests {
    static func dialog(
        owner: String = FirstOpenPolicy.owner, question: String = FirstOpenPolicy.question,
        assurance: String = FirstOpenPolicy.assurance, buttons: [String] = ["Cancel", "Open", "?"]
    ) -> FirstOpenDialog {
        FirstOpenDialog(
            owner: owner, ownerPath: FirstOpenPolicy.ownerPath, processID: 123,
            texts: [question, "Homebrew Cask downloaded this file today at 11:08 AM. " + assurance], buttons: buttons)
    }

    static func main() throws {
        var pressed = 0
        var events: [String] = []
        let good = dialog()
        try FirstOpenPolicy.confirm(FirstOpenActions(
            snapshot: { good }, screenshot: { events.append($0) }, authorize: { events.append("authorized") },
            pressOpen: { pressed += 1 }, record: { events.append($0.phase) }))
        precondition(pressed == 1 && events == ["observed", "first-open-before.png", "authorized", "authorized",
                                              "pressed", "first-open-after.png"])
        let unsafe = [
            dialog(owner: "other.app"), dialog(question: "MacSweep cannot be checked for malicious software."),
                      dialog(assurance: "Apple could not check it."), dialog(buttons: ["Cancel", "Open Anyway"]),
                      dialog(buttons: ["Cancel", "Open", "Allow"]), dialog(question: "Enter administrator password.")]
        for value in unsafe {
            do {
                try FirstOpenPolicy.confirm(FirstOpenActions(
                    snapshot: { value }, screenshot: { _ in }, authorize: {}, pressOpen: { pressed += 1 },
                    record: { _ in }))
                preconditionFailure("Unexpected dialog was accepted.")
            } catch { precondition(pressed == 1) }
        }
        var count = 0
        do {
            try FirstOpenPolicy.confirm(FirstOpenActions(
                snapshot: { count += 1; return count == 1 ? good : dialog(buttons: ["Cancel", "Open Anyway"]) },
                screenshot: { _ in }, authorize: {}, pressOpen: { pressed += 1 }, record: { _ in }))
            preconditionFailure("Changed dialog was accepted.")
        } catch { precondition(pressed == 1) }
        do {
            try FirstOpenPolicy.confirm(FirstOpenActions(
                snapshot: { good }, screenshot: { _ in },
                authorize: { throw FirstOpenFailure(message: "Identity changed") },
                pressOpen: { pressed += 1 }, record: { _ in }))
            preconditionFailure("Failed authorization was ignored.")
        } catch { precondition(pressed == 1) }
        print("First-open policy fixtures passed; only the exact verified normal Open can be pressed.")
    }
}
