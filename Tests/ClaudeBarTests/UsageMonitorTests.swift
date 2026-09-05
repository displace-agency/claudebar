import XCTest
@testable import ClaudeBar

final class UsageMonitorTests: XCTestCase {
    func testFailureRetainsOriginalReadingAndTimestamp() {
        let date = Date(timeIntervalSince1970: 100)
        let window = SubscriptionWindow(usedPercent: 75, resetsAt: date.addingTimeInterval(10080 * 60), durationMinutes: 10080)
        let old = SubscriptionUsage(provider: .claude, weekly: window, session: nil, fetchedAt: date, error: nil, plan: "max")
        let failed = SubscriptionUsage(provider: .claude, weekly: nil, session: nil, fetchedAt: Date(), error: "Offline", plan: nil)
        let retained = UsageMonitor.retainingLastKnown(failed, previous: old)
        XCTAssertEqual(retained.weekly?.usedPercent, 75)
        XCTAssertEqual(retained.fetchedAt, date)
        XCTAssertEqual(retained.error, "Offline")
        XCTAssertEqual(retained.plan, "max")
    }

    func testRecoveryReplacesPreviousUsageAndClearsError() {
        let old = SubscriptionUsage(provider: .codex, weekly: nil, session: nil, fetchedAt: .distantPast, error: "Offline", plan: nil)
        let date = Date()
        let fresh = SubscriptionUsage(provider: .codex, weekly: SubscriptionWindow(usedPercent: 0, resetsAt: date, durationMinutes: 10080), session: nil, fetchedAt: date, error: nil, plan: "pro")
        let result = UsageMonitor.retainingLastKnown(fresh, previous: old)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.weekly?.usedPercent, 0)
        XCTAssertEqual(result.fetchedAt, date)
    }
}
