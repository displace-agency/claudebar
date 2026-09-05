import Foundation
import SwiftUI

final class UsageMonitor: ObservableObject {
    @Published var snapshot: UsageSnapshot = .empty
    @Published var selectedProvider: SubscriptionProvider = .claude {
        didSet { snapshot = snapshots[selectedProvider] ?? .empty }
    }
    @Published var subscriptions: [SubscriptionProvider: SubscriptionUsage] = [:]
    @Published var menuBarText: String = "◐ …"
    @Published var menuBarColor: MenuBarTint = .neutral
    @Published var lastUpdated: Date?
    @Published var lastError: String?
    @Published var isLoading = false

    enum MenuBarTint { case neutral, green, amber, red }

    private var snapshots: [SubscriptionProvider: UsageSnapshot] = [:]
    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "agency.displace.ClaudeBar.fetch", qos: .utility)
    private let quotaService = SubscriptionUsageService()
    private var localInflight = false
    private var quotaInflight = false
    private var quotaTask: Task<Void, Never>?
    private var lastQuotaAttempt: Date?

    init(startAutomatically: Bool = true) {
        guard startAutomatically else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate(); quotaTask?.cancel() }

    func refresh() {
        // Claim the work on the main queue before enqueueing it. The previous
        // implementation guarded only its UI update, so repeated clicks queued scans.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        refreshMenuBar()
        if !localInflight {
            localInflight = true
            updateLoading()
            workQueue.async { [weak self] in
                let claude = TranscriptParser.shared.snapshot()
                let codex = CodexTranscriptParser.shared.snapshot()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.snapshots = [.claude: claude, .codex: codex]
                    self.snapshot = self.snapshots[self.selectedProvider] ?? .empty
                    self.lastUpdated = Date()
                    self.localInflight = false
                    self.updateLoading()
                    self.refreshMenuBar()
                }
            }
        }
        // Opening the popover also calls refresh; do not turn clicks into quota traffic.
        if !quotaInflight, lastQuotaAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            quotaInflight = true
            lastQuotaAttempt = Date()
            updateLoading()
            quotaTask = Task { @MainActor [weak self] in
                guard let self else { return }
                async let claude = self.quotaService.fetch(.claude)
                async let codex = self.quotaService.fetch(.codex)
                let results = await [claude, codex]
                guard !Task.isCancelled else { return }
                for result in results {
                    self.subscriptions[result.provider] = Self.retainingLastKnown(result, previous: self.subscriptions[result.provider])
                }
                self.quotaInflight = false
                self.updateLoading()
                self.refreshMenuBar()
            }
        }
    }

    static func retainingLastKnown(_ result: SubscriptionUsage, previous: SubscriptionUsage?) -> SubscriptionUsage {
        guard result.error != nil, let previous, previous.weekly != nil || previous.session != nil else { return result }
        return SubscriptionUsage(provider: result.provider, weekly: previous.weekly, session: previous.session,
                                 fetchedAt: previous.fetchedAt, error: result.error, plan: previous.plan)
    }

    private func updateLoading() { isLoading = localInflight || quotaInflight }

    private func refreshMenuBar() {
        let pieces = SubscriptionProvider.allCases.compactMap { provider -> String? in
            guard let usage = subscriptions[provider], let weekly = usage.weekly else { return nil }
            let name = provider == .claude ? "C" : "O"
            let stale = usage.error != nil || Date().timeIntervalSince(usage.fetchedAt) > 180
            let countdown: String
            if let reset = weekly.resetsAt, reset > Date(), reset.timeIntervalSinceNow < 31_557_600 {
                countdown = weekly.countdown(at: Date())
            } else {
                countdown = weekly.resetsAt == nil ? "?" : "due"
            }
            return "\(name) \(stale ? "~" : "")\(countdown)"
        }
        menuBarText = pieces.isEmpty ? "◐ RelayBar" : "◐ " + pieces.joined(separator: " · ")
        let values = subscriptions.values.filter { $0.error == nil && Date().timeIntervalSince($0.fetchedAt) <= 180 }
            .compactMap { usage -> Double? in
                guard let window = usage.weekly, let reset = window.resetsAt, reset > Date() else { return nil }
                return window.usedPercent
            }
        guard let used = values.max() else { menuBarColor = .neutral; return }
        menuBarColor = used >= 90 ? .red : used >= 70 ? .amber : .green
    }
}
