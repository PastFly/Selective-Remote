import Foundation

/// Serializes tests that temporarily change the process-wide application locale.
/// `@Suite(.serialized)` applies only inside one suite, not across test files.
enum LocalizationTestLanguageLock {
    private static let shared = NSRecursiveLock()

    static func acquire() {
        shared.lock()
    }

    static func release() {
        shared.unlock()
    }
}
