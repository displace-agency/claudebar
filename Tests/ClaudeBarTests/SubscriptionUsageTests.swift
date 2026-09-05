import XCTest
@testable import ClaudeBar

final class SubscriptionUsageTests: XCTestCase {
    func testClaudeFractionalDatesAndMissingSession() throws {
        let usage = try SubscriptionUsageService.parse(Data(#"{"seven_day":{"utilization":73.5,"resets_at":"2026-09-10T12:00:00.000Z"},"five_hour":null}"#.utf8), provider: .claude)
        XCTAssertEqual(usage.weekly?.usedPercent, 73.5)
        XCTAssertNotNil(usage.weekly?.resetsAt)
        XCTAssertNil(usage.session)
    }

    func testCodexUsesWindowDurationNotFieldPosition() throws {
        let usage = try SubscriptionUsageService.parse(Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":44,"limit_window_seconds":604800,"reset_at":2000000000},"secondary_window":{"used_percent":2,"limit_window_seconds":18000,"reset_at":1900000000}}}"#.utf8), provider: .codex)
        XCTAssertEqual(usage.weekly?.usedPercent, 44)
        XCTAssertEqual(usage.session?.usedPercent, 2)
        XCTAssertEqual(usage.weekly?.resetsAt?.timeIntervalSince1970, 2000000000)
        XCTAssertEqual(usage.plan, "pro")
    }

    func testUnknownAndBooleanUsageNeverBecomesZeroQuota() {
        for json in [#"{}"#, #"{"seven_day":{"utilization":true}}"#] {
            XCTAssertThrowsError(try SubscriptionUsageService.parse(Data(json.utf8), provider: .claude))
        }
    }

    func testMissingResetRemainsUnknown() throws {
        let usage = try SubscriptionUsageService.parse(Data(#"{"seven_day":{"utilization":0,"resets_at":null}}"#.utf8), provider: .claude)
        XCTAssertEqual(usage.weekly?.countdown(), "Reset time unavailable")
    }

    func testCountdownBoundaries() {
        let now = Date(timeIntervalSince1970: 100000)
        func countdown(_ seconds: Double) -> String {
            SubscriptionWindow(usedPercent: 0, resetsAt: now.addingTimeInterval(seconds), durationMinutes: 10080).countdown(at: now)
        }
        XCTAssertEqual(countdown(0), "Awaiting reset update")
        XCTAssertEqual(countdown(-100), "Awaiting reset update")
        XCTAssertEqual(countdown(1), "1m")
        XCTAssertEqual(countdown(3601), "1h 1m")
        XCTAssertEqual(countdown(90000), "1d 1h")
    }

    func testExtremeDurationsAreRejectedWithoutIntegerOverflow() {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":1e100}}}"#
        XCTAssertThrowsError(try SubscriptionUsageService.parse(Data(json.utf8), provider: .codex))
        let window = SubscriptionWindow(usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1e100), durationMinutes: 10080)
        XCTAssertEqual(window.countdown(), "Reset time unavailable")
    }

    private func fixtureService() throws -> (SubscriptionUsageService, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("relaybar-quota-test-" + UUID().uuidString)
        let auth = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"test-placeholder","account_id":"test-account"}}"#.utf8)
            .write(to: auth.appendingPathComponent("auth.json"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaURLProtocol.self]
        QuotaURLProtocol.count = 0
        return (SubscriptionUsageService(home: home, environment: [:], session: URLSession(configuration: config)), home)
    }

    func testUnauthorizedErrorNeverIncludesResponseBodyOrCredential() async throws {
        let (service, home) = try fixtureService()
        defer { try? FileManager.default.removeItem(at: home) }
        QuotaURLProtocol.status = 401
        QuotaURLProtocol.networkError = nil
        let usage = await service.fetch(.codex)
        XCTAssertNil(usage.weekly)
        XCTAssertEqual(usage.error, "Session expired or access denied. Open the CLI to reconnect.")
        XCTAssertFalse(usage.error?.contains("test-placeholder") ?? true)
    }

    func testRateLimitBackoffDoesNotRepeatRequest() async throws {
        let (service, home) = try fixtureService()
        defer { try? FileManager.default.removeItem(at: home) }
        QuotaURLProtocol.status = 429
        QuotaURLProtocol.networkError = nil
        let first = await service.fetch(.codex)
        let second = await service.fetch(.codex)
        XCTAssertEqual(first.error, "Usage checks are rate limited. Try again later.")
        XCTAssertEqual(second.error, first.error)
        XCTAssertEqual(QuotaURLProtocol.count, 1)
    }

    func testOfflineAndTimeoutErrorsAreSanitized() async throws {
        let (service, home) = try fixtureService()
        defer { try? FileManager.default.removeItem(at: home) }
        QuotaURLProtocol.networkError = .notConnectedToInternet
        let offline = await service.fetch(.codex)
        XCTAssertEqual(offline.error, "Usage is unavailable. Check your connection and try again.")
        QuotaURLProtocol.networkError = .timedOut
        let timeout = await service.fetch(.codex)
        XCTAssertEqual(timeout.error, "Usage check timed out. Try again later.")
        QuotaURLProtocol.networkError = nil
    }

    func testLiveUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RELAYBAR_LIVE_USAGE_TEST"] == "1" else { throw XCTSkip("Live quota check is opt-in") }
        let service = SubscriptionUsageService()
        for provider in SubscriptionProvider.allCases {
            let usage = await service.fetch(provider)
            print("QUOTA \(provider.rawValue): weekly=\(usage.weekly?.usedPercent.description ?? "unknown") session=\(usage.session?.usedPercent.description ?? "unknown") weeklyReset=\(usage.weekly?.resetsAt?.description ?? "unknown") error=\(usage.error ?? "none")")
            XCTAssertNil(usage.error, "\(provider.title) quota unavailable")
            XCTAssertNotNil(usage.weekly)
        }
    }
}

private final class QuotaURLProtocol: URLProtocol {
    static var status = 200
    static var networkError: URLError.Code?
    static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        if let error = Self.networkError {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("untrusted response test-placeholder".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
