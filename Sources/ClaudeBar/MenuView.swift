import SwiftUI
import ServiceManagement

struct MenuView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var selectedTab: Tab = .overview
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case sessions = "Sessions"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            tabBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                Group {
                    switch selectedTab {
                    case .overview: OverviewTab(snapshot: monitor.snapshot)
                    case .sessions: SessionsTab(snapshot: monitor.snapshot)
                    case .history: HistoryTab(snapshot: monitor.snapshot)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 420, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Usage").font(.headline)
                if let b = monitor.snapshot.activeBlock, let rate = b.burnRate {
                    Text("\(formatTokens(Int(rate.tokensPerMinute)))/min · \(b.projection?.remainingMinutes ?? 0) min left")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Idle").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: monitor.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(monitor.isLoading)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            if let updated = monitor.lastUpdated {
                Text(updated.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .keyboardShortcut("q")
        }
    }
}

private struct OverviewTab: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            todayBlock
            Divider()
            activeBlock
            Divider()
            modelsBlock
        }
    }

    private var todayBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today").sectionLabel()
            if let d = snapshot.today {
                HeroTokens(tokens: d.totalTokens, cost: d.costUSD)
                HStack(spacing: 14) {
                    Stat(label: "Input", value: formatTokens(d.tokens.inputTokens))
                    Stat(label: "Output", value: formatTokens(d.tokens.outputTokens))
                    Stat(label: "Cache write", value: formatTokens(d.tokens.cacheCreationInputTokens))
                    Stat(label: "Cache hits",
                         value: formatTokens(d.tokens.cacheHitTokens),
                         sub: String(format: "%.0f%% reuse", d.tokens.cacheHitRate * 100))
                }
                .padding(.top, 4)
            } else {
                Text("No usage today yet").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private var activeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active 5-hour block").sectionLabel()
            if let b = snapshot.activeBlock {
                HeroTokens(tokens: b.totalTokens, cost: b.costUSD)
                if let r = b.burnRate, let p = b.projection {
                    HStack(spacing: 14) {
                        Stat(label: "Rate", value: "\(formatTokens(Int(r.tokensPerMinute)))/min")
                        Stat(label: "Remaining", value: "\(p.remainingMinutes) min")
                        Stat(label: "Projected", value: formatTokens(p.totalTokens))
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("No activity in the last 5 hours").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private var modelsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models today").sectionLabel()
            if snapshot.modelsToday.isEmpty {
                Text("—").foregroundStyle(.secondary).font(.caption)
            } else {
                ModelBreakdownView(models: snapshot.modelsToday)
            }
        }
    }
}

private struct SessionsTab: View {
    let snapshot: UsageSnapshot
    @State private var sortMode: SortMode = .recent

    enum SortMode: String, CaseIterable {
        case recent = "Recent"
        case biggest = "Biggest"
    }

    private var sortedSessions: [SessionEntry] {
        switch sortMode {
        case .recent: return snapshot.sessions
        case .biggest: return snapshot.sessions.sorted { $0.tokens.totalTokens > $1.tokens.totalTokens }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions").sectionLabel()
                Spacer()
                Text("\(snapshot.sessions.count) total")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Picker("", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if snapshot.sessions.isEmpty {
                Text("No sessions found").foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(sortedSessions.prefix(40))) { s in
                        SessionRow(session: s)
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionEntry
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(session.projectPathShort)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(session.lastActivity.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text("\(session.messageCount) msg")
                    if let family = session.models.first.map(Pricing.family(for:)) {
                        Text("·")
                        Text(family)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatTokens(session.tokens.totalTokens))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text(String(format: "≈ $%.2f", session.costUSD))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct HistoryTab: View {
    let snapshot: UsageSnapshot

    private var last7DaysTokens: Int {
        Array(snapshot.daily.prefix(7)).reduce(0) { $0 + $1.totalTokens }
    }

    private var weeklyBuckets: [(weekStart: Date, tokens: Int, cost: Double)] {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.timeZone = TimeZone.current

        var buckets: [Date: (Int, Double)] = [:]
        for d in snapshot.daily {
            guard let date = inFmt.date(from: d.date),
                  let weekStart = cal.dateInterval(of: .weekOfYear, for: date)?.start
            else { continue }
            var entry = buckets[weekStart] ?? (0, 0)
            entry.0 += d.totalTokens
            entry.1 += d.costUSD
            buckets[weekStart] = entry
        }
        return buckets
            .map { (weekStart: $0.key, tokens: $0.value.0, cost: $0.value.1) }
            .sorted { $0.weekStart > $1.weekStart }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                TotalsCard(label: "Last 7 days", tokens: last7DaysTokens, cost: snapshot.last7DaysCost)
                TotalsCard(label: "Last 30 days", tokens: snapshot.last30DaysTokens, cost: snapshot.last30DaysCost)
                TotalsCard(
                    label: "All time",
                    tokens: snapshot.allTimeTokens,
                    cost: snapshot.allTimeCost,
                    sub: activeDaysSub
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Weekly tokens (last 12)").sectionLabel()
                let weeks = Array(weeklyBuckets.prefix(12))
                if weeks.isEmpty {
                    Text("—").foregroundStyle(.secondary).font(.caption)
                } else {
                    let maxTok = max(weeks.map(\.tokens).max() ?? 1, 1)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(weeks.reversed(), id: \.weekStart) { w in
                            VStack(spacing: 2) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(
                                        height: max(2, CGFloat(Double(w.tokens) / Double(maxTok)) * 60)
                                    )
                                Text(weekLabel(w.weekStart))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 80)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Daily tokens (last 30)").sectionLabel()
                let recent = Array(snapshot.daily.prefix(30))
                if recent.isEmpty {
                    Text("—").foregroundStyle(.secondary).font(.caption)
                } else {
                    let maxTok = max(recent.map(\.totalTokens).max() ?? 1, 1)
                    VStack(spacing: 4) {
                        ForEach(recent) { d in
                            HStack(spacing: 8) {
                                Text(shortDate(d.date))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading).monospacedDigit()
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.secondary.opacity(0.10))
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.accentColor.opacity(0.75))
                                            .frame(width: geo.size.width * CGFloat(Double(d.totalTokens) / Double(maxTok)))
                                    }
                                }
                                .frame(height: 8)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(formatTokens(d.totalTokens))
                                        .font(.caption2).monospacedDigit()
                                    Text(String(format: "≈ $%.0f", d.costUSD))
                                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                }
                                .frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private var activeDaysSub: String? {
        guard snapshot.activeDays > 0 else { return nil }
        if let first = snapshot.firstActiveDate {
            return "\(snapshot.activeDays) days · since \(shortMonthDay(first))"
        }
        return "\(snapshot.activeDays) active days"
    }

    private func shortMonthDay(_ iso: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.timeZone = TimeZone.current
        guard let date = inFmt.date(from: iso) else { return iso }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "MMM d"
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        return outFmt.string(from: date)
    }

    private func weekLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    private func shortDate(_ iso: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.timeZone = TimeZone.current
        guard let date = inFmt.date(from: iso) else { return iso }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "EEE d"
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        return outFmt.string(from: date)
    }
}

private struct HeroTokens: View {
    let tokens: Int
    let cost: Double
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatTokens(tokens))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("tokens")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "≈ $%.2f API", cost))
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

private struct TotalsCard: View {
    let label: String
    let tokens: Int
    let cost: Double
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(formatTokens(tokens))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(String(format: "≈ $%.0f API", cost))
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            if let sub {
                Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
            if let sub {
                Text(sub).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

private struct ModelBreakdownView: View {
    let models: [ModelUsage]
    var body: some View {
        let total = max(models.reduce(0) { $0 + $1.tokens.totalTokens }, 1)
        VStack(spacing: 5) {
            ForEach(models) { m in
                HStack(spacing: 8) {
                    Text(m.family)
                        .font(.caption).fontWeight(.medium)
                        .frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.10))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: m.family))
                                .frame(width: geo.size.width * CGFloat(Double(m.tokens.totalTokens) / Double(total)))
                        }
                    }
                    .frame(height: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatTokens(m.tokens.totalTokens))
                            .font(.caption2).monospacedDigit()
                        Text(String(format: "≈ $%.2f", m.costUSD))
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }
    private func color(for family: String) -> Color {
        switch family {
        case "Opus": return Color.purple.opacity(0.75)
        case "Sonnet": return Color.blue.opacity(0.75)
        case "Haiku": return Color.green.opacity(0.75)
        default: return Color.accentColor.opacity(0.75)
        }
    }
}

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

private extension Text {
    func sectionLabel() -> some View {
        self.font(.caption).fontWeight(.medium).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
