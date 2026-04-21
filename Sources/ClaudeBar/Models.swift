import Foundation

struct TokenCounts: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    var cacheReadInputTokens: Int = 0

    // "Total" = what was actually processed as new input plus generated output.
    // Excludes both cache_read (replayed context) and cache_creation (input
    // tokens that are also counted in inputTokens per Anthropic's billing).
    var totalTokens: Int {
        inputTokens + outputTokens
    }

    var cacheHitTokens: Int { cacheReadInputTokens }

    // Rough hit-rate: cache reads as share of total context this request saw.
    var cacheHitRate: Double {
        let contextTokens = inputTokens + cacheCreationInputTokens + cacheReadInputTokens
        guard contextTokens > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(contextTokens)
    }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheCreationInputTokens: a.cacheCreationInputTokens + b.cacheCreationInputTokens,
            cacheReadInputTokens: a.cacheReadInputTokens + b.cacheReadInputTokens
        )
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

struct ModelUsage: Identifiable, Equatable {
    var id: String { model }
    let model: String
    var tokens: TokenCounts
    var costUSD: Double
    var family: String { Pricing.family(for: model) }
}

struct BurnRate: Equatable {
    let tokensPerMinute: Double
    let costPerHour: Double
}

struct Projection: Equatable {
    let totalCost: Double
    let totalTokens: Int
    let remainingMinutes: Int
}

struct UsageBlock: Identifiable, Equatable {
    let id: String
    let startTime: Date
    let endTime: Date
    let lastActivity: Date
    let isActive: Bool
    var tokens: TokenCounts
    var costUSD: Double
    var models: [String]
    var burnRate: BurnRate?
    var projection: Projection?

    var totalTokens: Int { tokens.totalTokens }
}

struct DailyEntry: Identifiable, Equatable {
    var id: String { date }
    let date: String
    var tokens: TokenCounts
    var costUSD: Double
    var models: [String]
    var totalTokens: Int { tokens.totalTokens }
}

struct SessionEntry: Identifiable, Equatable {
    var id: String { sessionId }
    let sessionId: String
    let projectPath: String
    let inferredProject: String?
    let startTime: Date
    let lastActivity: Date
    var tokens: TokenCounts
    var costUSD: Double
    var models: [String]
    var messageCount: Int

    var projectName: String {
        let home = NSHomeDirectory()
        let pathComponent = (projectPath as NSString).lastPathComponent
        // When cwd is home (or empty), fall back to the hint we inferred from
        // user messages ("which website/tool are you in?"). Otherwise use the
        // cwd basename.
        if projectPath == home || projectPath.isEmpty {
            return inferredProject ?? "Home"
        }
        return pathComponent.isEmpty ? (inferredProject ?? "Home") : pathComponent
    }

    /// `~/…` display of the parent folder. Marks inferred names with `~ (inferred)`.
    var projectPathShort: String {
        let home = NSHomeDirectory()
        let isHome = projectPath == home || projectPath.isEmpty
        if isHome {
            return inferredProject != nil ? "~ (inferred)" : "~"
        }
        let parent = (projectPath as NSString).deletingLastPathComponent
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") {
            return "~/" + String(parent.dropFirst(home.count + 1))
        }
        return parent
    }
}

struct UsageSnapshot: Equatable {
    var activeBlock: UsageBlock?
    var today: DailyEntry?
    var daily: [DailyEntry]
    var sessions: [SessionEntry]
    var modelsToday: [ModelUsage]
    var last7DaysCost: Double
    var last30DaysCost: Double
    var last30DaysTokens: Int
    var monthCost: Double
    var allTimeTokens: Int
    var allTimeCost: Double
    var activeDays: Int
    var firstActiveDate: String?

    static let empty = UsageSnapshot(
        activeBlock: nil, today: nil, daily: [], sessions: [], modelsToday: [],
        last7DaysCost: 0, last30DaysCost: 0, last30DaysTokens: 0, monthCost: 0,
        allTimeTokens: 0, allTimeCost: 0, activeDays: 0, firstActiveDate: nil
    )
}
