import Foundation

/// Turns known `tart run` failures in its log into advice the user can act on.
public enum LaunchHints {
    /// A hint for a `tart run` log, or nil when nothing known matched.
    public static func hint(forLog log: String) -> String? {
        if log.contains("without a machine identifier cannot be suspended") {
            return "This Linux VM was created by an older tart and can't be suspended. Turn off \"Allow suspend\" in its Run options and start it again."
        }
        if log.contains("This platform is not suspendable") {
            return "This VM can't be suspended. Turn off \"Allow suspend\" in its Run options and start it again."
        }
        if log.contains("Unknown option '--suspendable'") {
            return "This version of tart doesn't support suspending. Update tart (`brew upgrade cirruslabs/cli/tart`) or turn off \"Allow suspend\" in the VM's Run options."
        }
        return nil
    }

    /// The reason tart gave for a failed suspend, from the VM's `tart run` log.
    /// tart prints "Failed to suspend the VM: <reason>" before shutting the VM down.
    public static func suspendFailure(inLog log: String) -> String? {
        log.split(separator: "\n")
            .last { $0.contains("Failed to suspend the VM") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func suspendFailure(inLog url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { suspendFailure(inLog: $0) }
    }
}
