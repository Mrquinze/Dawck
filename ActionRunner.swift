import Foundation
import AppKit

/// Executes an action tile. Everything here runs off the main thread and
/// reports failure through a callback rather than throwing into the view —
/// a dock tile that fails should say so once, not take the panel down.
enum ActionRunner {

    enum Failure: LocalizedError {
        case emptyPayload
        /// The action arrived with an imported profile and has not been approved.
        case needsApproval
        case malformedURL(String)
        case launchFailed(String)
        case scriptError(String)

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                return "This action has nothing to run yet."
            case .needsApproval:
                return "This action came from an imported profile. Click it on its dock, or open it in Dawck's settings, to review and approve it first."
            case .malformedURL(let value):
                return "\"\(value)\" isn't a URL macOS can open."
            case .launchFailed(let message):
                return message
            case .scriptError(let message):
                return message
            }
        }
    }

    /// - Parameter completion: called on the main queue; `nil` means success.
    static func run(_ item: DockItem, completion: @escaping (Failure?) -> Void = { _ in }) {
        // Every way of running an action passes through here, so the trust check
        // can't be bypassed by a menu, a menu bar item or a test button.
        guard item.isTrusted else {
            DispatchQueue.main.async { completion(.needsApproval) }
            return
        }
        let payload = item.actionPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            DispatchQueue.main.async { completion(.emptyPayload) }
            return
        }

        switch item.actionType {
        case .url:
            openURL(payload, completion: completion)
        case .shortcut:
            // `shortcuts run` blocks for the whole duration of the shortcut,
            // which can be many seconds, so it is never waited on.
            spawn("/usr/bin/shortcuts", ["run", payload], completion: completion)
        case .shell:
            // `-l` so the command sees the user's login PATH — without it,
            // anything installed by Homebrew is simply "not found", which is
            // the most common way a working command fails inside a GUI app.
            spawn("/bin/zsh", ["-l", "-c", payload], completion: completion)
        case .appleScript:
            runAppleScript(payload, completion: completion)
        }
    }

    private static func openURL(_ string: String, completion: @escaping (Failure?) -> Void) {
        // Deep links routinely contain characters that are legal in a URL only
        // once encoded (spaces in a Things query, `#` in a Slack link). Trying
        // the raw string first preserves anything already encoded correctly;
        // the percent-encoded retry rescues the rest.
        let url = URL(string: string)
            ?? string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))

        guard let url else {
            DispatchQueue.main.async { completion(.malformedURL(string)) }
            return
        }

        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                completion(error.map { .launchFailed($0.localizedDescription) })
            }
        }
    }

    private static func spawn(_ executable: String, _ arguments: [String], completion: @escaping (Failure?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(.launchFailed(error.localizedDescription)) }
                return
            }

            // The pipe is drained before waiting: a command that writes more
            // than the pipe buffer holds would otherwise block forever on the
            // write while this thread blocks forever on the wait.
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus != 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                completion(.launchFailed(message.isEmpty ? "Exited with status \(process.terminationStatus)." : message))
            }
        }
    }

    private static func runAppleScript(_ source: String, completion: @escaping (Failure?) -> Void) {
        // NSAppleScript is not thread-safe and must be built and executed on
        // the main thread. It blocks for the script's duration, so this is
        // hopped to the next main-queue turn rather than run inline — that way
        // the click that triggered it finishes handling first and the UI
        // doesn't appear to freeze mid-gesture.
        DispatchQueue.main.async {
            guard let script = NSAppleScript(source: source) else {
                completion(.scriptError("Couldn't compile that AppleScript."))
                return
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let message = errorInfo?[NSAppleScript.errorMessage] as? String {
                completion(.scriptError(message))
            } else {
                completion(nil)
            }
        }
    }
}
