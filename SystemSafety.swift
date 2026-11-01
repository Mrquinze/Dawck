import Foundation

/// The single gate in front of everything Dawck can do to state outside its
/// own preferences: the real Dock's settings, global defaults, and restarting
/// the Dock.
///
/// Why this exists: Dawck's job is to change the real Dock, which makes any
/// development or test build dangerous to run on a machine that is also in
/// daily use — a stray click in a test session once hid a real Dock. A build
/// whose bundle identifier is not the shipping one therefore refuses every
/// system write (it logs what it *would* have done and carries on), so a dev
/// build can be driven, scripted and benchmarked freely. Setting
/// `DAWCK_ALLOW_SYSTEM_WRITES=1` opts back in deliberately.
enum SystemSafety {
    static let productionBundleID = "com.matanlevi.Dawck"

    static var allowsSystemWrites: Bool {
        if ProcessInfo.processInfo.environment["DAWCK_ALLOW_SYSTEM_WRITES"] == "1" { return true }
        return Bundle.main.bundleIdentifier == productionBundleID
    }

    /// True when the write may go ahead. When it may not, says so in the log
    /// so a dev run still shows what the shipping build would have done.
    static func permit(_ description: @autoclosure () -> String) -> Bool {
        guard allowsSystemWrites else {
            NSLog("Dawck [safe mode]: skipped system write — \(description())")
            return false
        }
        return true
    }
}
