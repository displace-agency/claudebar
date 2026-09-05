import XCTest
import SwiftUI
import AppKit
import Vision
@testable import ClaudeBar

/// Opt-in, read-only capture of real subscriptions and aggregate local usage.
/// Never capture sessions or other views containing projects or conversation data.
final class MarketingCaptureTests: XCTestCase {
    @MainActor
    func testCaptureLiveMarketingScreenshots() async throws {
        guard ProcessInfo.processInfo.environment["RELAYBAR_MARKETING_CAPTURE"] == "1" else {
            throw XCTSkip("Set RELAYBAR_MARKETING_CAPTURE=1 to capture live account data offscreen.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("docs/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let service = SubscriptionUsageService()
        async let claudeRead = service.fetch(.claude)
        async let codexRead = service.fetch(.codex)
        let (claude, codex) = await (claudeRead, codexRead)
        XCTAssertNil(claude.error, claude.error ?? "")
        XCTAssertNil(codex.error, codex.error ?? "")
        _ = try XCTUnwrap(claude.weekly)
        _ = try XCTUnwrap(codex.weekly)
        let now = Date()
        let monitor = UsageMonitor(startAutomatically: false)
        monitor.subscriptions = [.claude: claude, .codex: codex]
        monitor.lastUpdated = now
        for (name, scheme) in [("relaybar-limits-light", ColorScheme.light), ("relaybar-limits-dark", .dark)] {
            let bitmap = try render(MenuView(monitor: monitor), scheme: scheme, now: now)
            let recognized = try text(in: bitmap)
            XCTAssertTrue(recognized.contains("Claude"))
            XCTAssertTrue(recognized.contains("Codex"))
            XCTAssertGreaterThanOrEqual(recognized.components(separatedBy: "% remaining").count - 1, 2)
            XCTAssertGreaterThanOrEqual(recognized.components(separatedBy: "Resets in").count - 1, 2)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        monitor.selectedProvider = .codex
        monitor.snapshot = CodexTranscriptParser().snapshot()
        let bitmap = try render(MenuView(monitor: monitor, initialTab: .overview), scheme: .light, now: now)
        let recognized = try text(in: bitmap)
        XCTAssertTrue(recognized.contains("Codex"))
        XCTAssertTrue(recognized.lowercased().contains("tokens"))
        XCTAssertFalse(recognized.contains("$"))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("relaybar-codex-overview.png"))
        if let manifestDirectory = ProcessInfo.processInfo.environment["RELAYBAR_CAPTURE_MANIFEST_DIR"] {
            let provenance = "Live RelayBar marketing captures\nCaptured: \(ISO8601DateFormatter().string(from: now))\nClaude reading: \(ISO8601DateFormatter().string(from: claude.fetchedAt))\nCodex reading: \(ISO8601DateFormatter().string(from: codex.fetchedAt))\nLimits use actual authenticated subscription GET responses. Overview uses actual local aggregate Codex token activity. No synthetic values, sessions, project names, account identifiers, or desktop pixels. Offscreen NSHostingView rendered at 3x.\n"
            try Data(provenance.utf8).write(to: URL(fileURLWithPath: manifestDirectory).appendingPathComponent("CAPTURE-PROVENANCE.txt"))
        }
    }

    @MainActor
    func testCaptureLiveCodexOverview() throws {
        guard ProcessInfo.processInfo.environment["RELAYBAR_MARKETING_CAPTURE"] == "overview" else {
            throw XCTSkip("Set RELAYBAR_MARKETING_CAPTURE=overview to refresh only the local Codex overview.")
        }
        let monitor = UsageMonitor(startAutomatically: false)
        monitor.selectedProvider = .codex
        monitor.snapshot = CodexTranscriptParser().snapshot()
        let now = Date()
        monitor.lastUpdated = now
        let bitmap = try render(MenuView(monitor: monitor, initialTab: .overview), scheme: .light, now: now)
        let recognized = try text(in: bitmap)
        XCTAssertTrue(recognized.contains("Codex"))
        XCTAssertTrue(recognized.lowercased().contains("tokens"))
        XCTAssertFalse(recognized.contains("$"))
        XCTAssertFalse(recognized.contains("No activity"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("docs/screenshots/relaybar-codex-overview.png"))
        if let manifestDirectory = ProcessInfo.processInfo.environment["RELAYBAR_CAPTURE_MANIFEST_DIR"] {
            try Data("Codex overview refreshed from live local aggregate activity: \(ISO8601DateFormatter().string(from: now))\nNo project names, session lists, conversations or account identifiers.\n".utf8)
                .write(to: URL(fileURLWithPath: manifestDirectory).appendingPathComponent("OVERVIEW-PROVENANCE.txt"))
        }
    }

    private func text(in bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    @MainActor
    private func render<V: View>(_ view: V, scheme: ColorScheme, now: Date) throws -> NSBitmapImageRep {
        let root = view.environment(\.subscriptionPreviewDate, now)
            .environment(\.colorScheme, scheme)
            .tint(Color.blue)
            .accentColor(.blue)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.98))
        let hosting = NSHostingView(rootView: root.scaleEffect(3, anchor: .topLeading)
            .frame(width: 1260, height: 1560, alignment: .topLeading))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 1260, height: 1560)
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        func sharpen(_ layer: CALayer) {
            layer.contentsScale = 3
            layer.shouldRasterize = false
            layer.sublayers?.forEach(sharpen)
            layer.setNeedsDisplay()
        }
        func sharpenViews(_ view: NSView) {
            view.wantsLayer = true
            if let layer = view.layer { sharpen(layer) }
            view.subviews.forEach(sharpenViews)
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        sharpenViews(hosting)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1260, pixelsHigh: 1560,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 1260, height: 1560)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
