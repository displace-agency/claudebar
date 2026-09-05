import XCTest
@testable import ClaudeBar

final class CodexTranscriptParserTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private let iso = ISO8601DateFormatter()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    private func metadata(_ id: String = "session-one", model: String = "gpt-5-codex") -> String {
        """
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/projects/example"}}
        {"type":"turn_context","payload":{"model":"\(model)"}}
        """
    }
    private func usage(_ date: String, input: Int, cached: Int = 0, output: Int) -> String {
        """
        {"timestamp":"\(date)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":10}}}}
        """
    }
    private func write(_ file: String, _ lines: [String]) throws {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func parser() -> CodexTranscriptParser {
        CodexTranscriptParser(roots: [root], now: { self.iso.date(from: "2026-09-05T12:00:00Z")! }, calendar: calendar)
    }

    func testCumulativeCopiesResumeModelsAndCacheAreNotDoubleCounted() throws {
        let initial = [metadata(), usage("2026-09-04T10:00:00Z", input: 100, cached: 40, output: 20),
                       usage("2026-09-04T10:01:00Z", input: 100, cached: 40, output: 20)]
        try write("sessions/nested/first.jsonl", initial)
        try write("archived_sessions/copy.jsonl", initial)
        try write("sessions/resumed.jsonl", [metadata(model: "gpt-6"),
            usage("2026-09-05T10:00:00Z", input: 180, cached: 70, output: 50)])
        let result = parser().snapshot()
        XCTAssertEqual(result.allTimeTokens, 160) // 110 fresh input + 50 output
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.tokens.cacheReadInputTokens, 70)
        XCTAssertEqual(result.sessions.first?.messageCount, 2)
        XCTAssertEqual(result.today?.totalTokens, 80)
        XCTAssertEqual(result.modelsToday.first?.model, "gpt-6")
        XCTAssertEqual(result.sessions.first?.models, ["gpt-5-codex", "gpt-6"])
        XCTAssertEqual(result.allTimeCost, 0)
        XCTAssertNil(result.activeBlock)
    }

    func testTrailingPartialLineIsIgnoredAndAppendedUsageRefreshesCache() throws {
        let parser = parser()
        let lines = [metadata(), usage("2026-09-05T10:00:00Z", input: 10, output: 2)]
        try write("sessions/file.jsonl", lines + ["{\"type\":\"event_msg\""])
        XCTAssertEqual(parser.snapshot().allTimeTokens, 12)
        try write("sessions/file.jsonl", lines + [usage("2026-09-05T11:00:00Z", input: 20, output: 5)])
        XCTAssertEqual(parser.snapshot().allTimeTokens, 25)
        XCTAssertEqual(parser.snapshot().allTimeTokens, 25)
    }

    func testThirtyDayWindowUsesCalendarDaysAndSessionsStayIndependent() throws {
        try write("old.jsonl", [metadata("old"), usage("2026-08-01T10:00:00Z", input: 100, output: 10)])
        try write("recent.jsonl", [metadata("recent"), usage("2026-09-05T10:00:00Z", input: 20, output: 5)])
        let result = parser().snapshot()
        XCTAssertEqual(result.allTimeTokens, 135)
        XCTAssertEqual(result.last30DaysTokens, 25)
        XCTAssertEqual(result.activeDays, 2)
        XCTAssertEqual(result.firstActiveDate, "2026-08-01")
        XCTAssertEqual(result.sessions.count, 2)
    }

    func testMissingRootsAndNoUsageYieldEmptySnapshot() {
        XCTAssertEqual(parser().snapshot(), .empty)
    }
}
