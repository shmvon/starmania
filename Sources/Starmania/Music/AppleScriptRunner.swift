import Foundation

/// Runs AppleScript on a dedicated serial queue so Apple Event round trips to Music
/// never block the main thread. Static scripts can be cached in compiled form.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "com.starmania.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]  // Only touched on `queue`

    private init() {}

    /// Run a script and return its string result (nil on error).
    func run(_ source: String, cache: Bool = false) async -> String? {
        await execute(source, cache: cache) { $0.stringValue }
    }

    /// Run a script and return its raw data result (e.g. artwork bytes).
    func runData(_ source: String) async -> Data? {
        let data = await execute(source, cache: false) { $0.data }
        return data?.isEmpty == false ? data : nil
    }

    /// Execute on the queue and convert the (non-Sendable) descriptor there.
    private func execute<T: Sendable>(
        _ source: String,
        cache: Bool,
        convert: @escaping @Sendable (NSAppleEventDescriptor) -> T?
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            queue.async {
                let result = self.executeOnQueue(source, cache: cache).flatMap(convert)
                continuation.resume(returning: result)
            }
        }
    }

    private func executeOnQueue(_ source: String, cache: Bool) -> NSAppleEventDescriptor? {
        let script: NSAppleScript?
        if cache, let existing = compiled[source] {
            script = existing
        } else {
            script = NSAppleScript(source: source)
            if cache, let script { compiled[source] = script }
        }

        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)

        if let error = error {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            // Don't spam logs for expected errors (Music not playing, etc.)
            if !errorMsg.contains("Can’t get current track") && !errorMsg.contains("Can't get current track") {
                print("[Starmania] AppleScript error: \(errorMsg)")
            }
            return nil
        }
        return result
    }
}
