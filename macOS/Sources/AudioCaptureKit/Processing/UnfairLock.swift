import Foundation

/// A thread-safe wrapper around `os_unfair_lock` that provides `Sendable`-safe locking.
///
/// This type provides synchronous mutual exclusion without the restrictions
/// that Swift 6 places on `NSLock` in async contexts. The `withLock` closure
/// runs synchronously and never suspends, so it is safe to call from any context.
package final class UnfairLock<Value: ~Copyable>: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _value: Value

    /// Creates a new lock protecting the given value.
    package init(_ value: consuming Value) {
        _value = value
    }

    /// Executes a closure while holding the lock.
    ///
    /// The closure receives an inout reference to the protected value.
    /// The lock is always released, even if the closure throws.
    @discardableResult
    package func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return try body(&_value)
    }
}
