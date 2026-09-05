import XCTest
import SwiftUI
import AppKit
import Vision
@testable import ClaudeBar

final class PreviewTests: XCTestCase {
    func testCalendarRangesExcludeOldActiveDaysAndFutureDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!
        let entries = ["2026-09-06", "2026-09-05", "2026-08-30", "2026-08-29", "2026-08-07", "2026-08-06"].map {
            DailyEntry(date: $0, tokens: TokenCounts(inputTokens: 100), costUSD: 1, models: [])
        }
        XCTAssertEqual(calendarDays(entries, count: 7, now: now, calendar: calendar).map(\.date), ["2026-09-05", "2026-08-30"])
        XCTAssertEqual(calendarDays(entries, count: 30, now: now, calendar: calendar).map(\.date), ["2026-09-05", "2026-08-30", "2026-08-29", "2026-08-07"])
    }

    @MainActor
    func testOffscreenMenuPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["RELAYBAR_PREVIEW_DIR"] else {
            throw XCTSkip("Set RELAYBAR_PREVIEW_DIR to render offscreen fixture previews.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let monitor = UsageMonitor(startAutomatically: false)
        monitor.subscriptions = [
            .claude: SubscriptionUsage(provider: .claude,
                weekly: SubscriptionWindow(usedPercent: 37, resetsAt: now.addingTimeInterval(3 * 86400 + 7 * 3600), durationMinutes: 10080),
                session: SubscriptionWindow(usedPercent: 18, resetsAt: now.addingTimeInterval(2 * 3600 + 23 * 60), durationMinutes: 300),
                fetchedAt: now, error: nil, plan: "Max"),
            .codex: SubscriptionUsage(provider: .codex,
                weekly: SubscriptionWindow(usedPercent: 76, resetsAt: now.addingTimeInterval(86400 + 4 * 3600), durationMinutes: 10080),
                session: SubscriptionWindow(usedPercent: 29, resetsAt: now.addingTimeInterval(3 * 3600 + 10 * 60), durationMinutes: 300),
                fetchedAt: now, error: nil, plan: "Pro")
        ]
        for (name, scheme) in [("limits-light", ColorScheme.light), ("limits-dark", .dark)] {
            let view = MenuView(monitor: monitor)
                .environment(\.controlActiveState, .active)
                .environment(\.subscriptionPreviewDate, now)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.98))
            let bitmap = try render(view)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 420)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 520)
            let recognized = try recognizedText(bitmap)
            XCTAssertTrue(recognized.contains("Claude"), recognized)
            XCTAssertTrue(recognized.contains("Codex"), recognized)
            XCTAssertTrue(recognized.contains("63% remaining"), recognized)
            XCTAssertTrue(recognized.contains("24% remaining"), recognized)
            XCTAssertTrue(recognized.contains("Resets in 3d 7h"), recognized)
            XCTAssertTrue(recognized.contains("Resets in 1d 4h"), recognized)
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        monitor.subscriptions = [.claude: SubscriptionUsage(provider: .claude, weekly: nil, session: nil,
            fetchedAt: now, error: "Session expired or access denied. Open the CLI to reconnect.", plan: nil)]
        let bitmap = try render(MenuView(monitor: monitor).environment(\.controlActiveState, .active)
                .environment(\.subscriptionPreviewDate, now).environment(\.colorScheme, .light).background(Color(white: 0.98)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("limits-unavailable.png"))
        try Data("Disposable RelayBar QA previews. Synthetic subscription fixtures only. Rendered offscreen without activating an app or capturing the screen.\n".utf8)
            .write(to: output.appendingPathComponent("MANIFEST.txt"))
    }

    private func recognizedText(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    @MainActor
    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
