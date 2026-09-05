import SwiftUI

struct SubscriptionView: View {
    let subscriptions: [SubscriptionProvider: SubscriptionUsage]
    let isLoading: Bool
    @Environment(\.subscriptionPreviewDate) private var previewDate

    var body: some View {
        if let previewDate {
            content(now: previewDate)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SubscriptionProvider.allCases, id: \.self) { provider in
                    providerCard(provider, now: now)
                }
                Text("Codex limits apply to Codex usage on your ChatGPT plan. Local token totals are separate activity records.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
    }

    private func providerCard(_ provider: SubscriptionProvider, now: Date) -> some View {
        let usage = subscriptions[provider]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 13, weight: .semibold))
                if let plan = usage?.plan, !plan.isEmpty {
                    Text(plan).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if let usage {
                    Text(usage.error != nil ? "Needs attention" : "Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(usage.error != nil ? .orange : .secondary)
                }
            }
            if let weekly = usage?.weekly {
                window(weekly, title: "Weekly", prominent: true, now: now)
            } else {
                Text(isLoading && usage == nil ? "Reading weekly limits…" : "Weekly limit unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let session = usage?.session {
                Divider()
                HStack {
                    Text("Session · \(Int(min(100, max(0, 100 - session.usedPercent))))% left")
                    Spacer()
                    Text(session.resetsAt == nil ? "Reset unavailable" : "Resets in \(session.countdown(at: now))")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .help(session.resetsAt.map { "Session resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset time unavailable")
            }
            if let error = usage?.error {
                if usage?.weekly != nil || usage?.session != nil {
                    Text("Last known reading").font(.caption2).fontWeight(.medium).foregroundStyle(.orange)
                }
                Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let usage, now.timeIntervalSince(usage.fetchedAt) > 180 {
                Text("Last reading is over 3 minutes old. Refresh to check current limits.")
                    .font(.caption2).foregroundStyle(.orange)
            } else if usage == nil && !isLoading {
                Text("Refresh to read this subscription.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func window(_ quota: SubscriptionWindow, title: String, prominent: Bool, now: Date) -> some View {
        let remaining = min(100, max(0, 100 - quota.usedPercent))
        let expired = quota.resetsAt.map { $0 <= now } ?? false
        return VStack(alignment: .leading, spacing: prominent ? 6 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%% remaining", remaining))
                    .font(.system(size: prominent ? 19 : 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(expired ? .secondary : .primary)
            }
            if prominent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(remaining <= 10 ? Color.orange : Color.accentColor)
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }
                .frame(height: 6)
                .accessibilityLabel("\(title): \(Int(remaining)) percent remaining")
            }
            if let reset = quota.resetsAt {
                VStack(alignment: .leading, spacing: 2) {
                    Text(expired ? "Reset due · refresh to verify" : "Resets in \(quota.countdown(at: now))")
                        .font(.system(size: prominent && !expired ? 19 : 12, weight: prominent ? .medium : .regular, design: .rounded))
                        .monospacedDigit()
                    Text(reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .help("Reset time in \(TimeZone.current.identifier)")
            } else {
                Text("Reset time unavailable").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SubscriptionPreviewDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// A fixed date makes offscreen fixture renders deterministic; production uses TimelineView.
    var subscriptionPreviewDate: Date? {
        get { self[SubscriptionPreviewDateKey.self] }
        set { self[SubscriptionPreviewDateKey.self] = newValue }
    }
}
