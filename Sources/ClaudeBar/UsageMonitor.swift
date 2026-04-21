import Foundation
import SwiftUI

final class UsageMonitor: ObservableObject {
    @Published var snapshot: UsageSnapshot = .empty
    @Published var menuBarText: String = "CC …"
    @Published var menuBarColor: MenuBarTint = .neutral
    @Published var lastUpdated: Date?
    @Published var lastError: String?
    @Published var isLoading: Bool = false

    enum MenuBarTint {
        case neutral, green, amber, red
    }

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 60
    private let workQueue = DispatchQueue(label: "agency.displace.ClaudeBar.fetch", qos: .userInitiated)
    private var inflight = false

    init() {
        scheduleRefresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() { scheduleRefresh() }

    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.inflight else { return }
            self.inflight = true
            self.isLoading = true
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            let snap = TranscriptParser.shared.snapshot()
            DispatchQueue.main.async {
                self.apply(snapshot: snap)
                self.inflight = false
                self.isLoading = false
            }
        }
    }

    private func apply(snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        self.lastError = nil
        self.lastUpdated = Date()
        self.menuBarText = Self.formatMenuBar(snapshot: snapshot)
        self.menuBarColor = Self.tint(for: snapshot.activeBlock)
    }

    private static func formatMenuBar(snapshot: UsageSnapshot) -> String {
        if let b = snapshot.activeBlock {
            return "◐ \(formatTokensCompact(b.totalTokens))"
        }
        if let t = snapshot.today {
            return "◐ \(formatTokensCompact(t.totalTokens))"
        }
        return "◐ —"
    }

    private static func formatTokensCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func tint(for block: UsageBlock?) -> MenuBarTint {
        guard let b = block, let rate = b.burnRate else { return .neutral }
        if rate.costPerHour >= 15 { return .red }
        if rate.costPerHour >= 5 { return .amber }
        return .green
    }
}
