import Foundation

private struct RawEvent {
    let timestamp: Date
    let sessionId: String
    let projectPath: String
    let model: String
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
    let dedupKey: String
}

private struct FileCache {
    let mtime: Date
    let size: Int64
    let events: [RawEvent]
    let inferredProject: String?
}

final class TranscriptParser {
    static let shared = TranscriptParser()

    private let projectsRoot: URL
    private let blockDuration: TimeInterval = 5 * 60 * 60
    private var fileCache: [String: FileCache] = [:]
    private var sessionHints: [String: String] = [:]
    private var seenDedupKeys: Set<String> = []
    private let iso = ISO8601DateFormatter()
    private let websitesRegex = try! NSRegularExpression(
        pattern: #"/websites/(?:\*[^/\s"]+/)?([A-Za-z][A-Za-z0-9_.-]*)"#
    )
    private let clientsRegex = try! NSRegularExpression(
        pattern: #"CLIENTS/(?:\*[^/\s"]+/)?([A-Za-z][A-Za-z0-9_. -]*?)(?=[/"\\])"#
    )

    init() {
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func snapshot() -> UsageSnapshot {
        let events = loadAllEvents()
        guard !events.isEmpty else { return .empty }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let blocks = buildBlocks(events: sorted)
        let daily = buildDaily(events: sorted)
        let sessions = buildSessions(events: sorted)
        let modelsToday = buildModelsForToday(events: sorted)

        let today = daily.first(where: { $0.date == Self.todayString() })
        let todayIdx = daily.firstIndex(where: { $0.date == Self.todayString() }) ?? 0
        let recent = Array(daily.prefix(todayIdx + 7))
        let last7 = Array(daily.prefix(7)).reduce(0) { $0 + $1.costUSD }
        let last30 = Array(daily.prefix(30))
        let last30Cost = last30.reduce(0) { $0 + $1.costUSD }
        let last30Tok = last30.reduce(0) { $0 + $1.totalTokens }
        let monthPrefix = String(Self.todayString().prefix(7))
        let monthCost = daily.filter { $0.date.hasPrefix(monthPrefix) }.reduce(0) { $0 + $1.costUSD }
        _ = recent

        let active = blocks.last.flatMap { $0.isActive ? $0 : nil }

        let allTimeTokens = daily.reduce(0) { $0 + $1.totalTokens }
        let allTimeCost = daily.reduce(0) { $0 + $1.costUSD }
        let firstActiveDate = daily.last?.date

        return UsageSnapshot(
            activeBlock: active,
            today: today,
            daily: daily,
            sessions: sessions,
            modelsToday: modelsToday,
            last7DaysCost: last7,
            last30DaysCost: last30Cost,
            last30DaysTokens: last30Tok,
            monthCost: monthCost,
            allTimeTokens: allTimeTokens,
            allTimeCost: allTimeCost,
            activeDays: daily.count,
            firstActiveDate: firstActiveDate
        )
    }

    private func loadAllEvents() -> [RawEvent] {
        guard let files = Self.globJSONLFiles(root: projectsRoot) else { return [] }
        var allEvents: [RawEvent] = []
        var livePaths: Set<String> = []
        sessionHints.removeAll(keepingCapacity: true)

        for url in files {
            livePaths.insert(url.path)
            let sessionId = url.deletingPathExtension().lastPathComponent
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            if let cached = fileCache[url.path],
               cached.mtime == mtime, cached.size == size {
                allEvents.append(contentsOf: cached.events)
                if let hint = cached.inferredProject { sessionHints[sessionId] = hint }
                continue
            }

            let (parsed, hint) = parseFile(at: url)
            fileCache[url.path] = FileCache(mtime: mtime, size: size, events: parsed, inferredProject: hint)
            allEvents.append(contentsOf: parsed)
            if let hint { sessionHints[sessionId] = hint }
        }

        for path in fileCache.keys where !livePaths.contains(path) {
            fileCache.removeValue(forKey: path)
        }

        var dedup: Set<String> = []
        var out: [RawEvent] = []
        out.reserveCapacity(allEvents.count)
        for e in allEvents {
            if dedup.insert(e.dedupKey).inserted {
                out.append(e)
            }
        }
        return out
    }

    private func parseFile(at url: URL) -> ([RawEvent], String?) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let text = String(data: data, encoding: .utf8) else { return ([], nil) }

        let sessionId = url.deletingPathExtension().lastPathComponent
        var events: [RawEvent] = []
        events.reserveCapacity(256)

        var hintCounts: [String: Int] = [:]
        var linesScannedForHint = 0

        text.enumerateLines { line, _ in
            if linesScannedForHint < 40,
               line.contains("/websites/") || line.contains("CLIENTS/") {
                for name in self.extractProjectHints(from: line) {
                    hintCounts[name, default: 0] += 1
                }
            }
            linesScannedForHint += 1
            guard !line.isEmpty, line.contains("\"usage\"") else { return }
            guard let lineData = line.data(using: .utf8) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            let model = (message["model"] as? String) ?? "unknown"
            if model == "<synthetic>" { return }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0

            guard input + output + cacheCreation + cacheRead > 0 else { return }

            guard let timestampStr = obj["timestamp"] as? String,
                  let timestamp = self.parseDate(timestampStr) else { return }

            let cwd = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let projectPath = cwd
                ?? Self.decodeProjectFolder(url.deletingLastPathComponent().lastPathComponent)

            let messageId = (message["id"] as? String) ?? ""
            let requestId = (obj["requestId"] as? String) ?? ""
            let dedupKey = messageId.isEmpty && requestId.isEmpty
                ? "\(sessionId):\(timestampStr)"
                : "\(messageId):\(requestId)"

            events.append(RawEvent(
                timestamp: timestamp,
                sessionId: sessionId,
                projectPath: projectPath,
                model: model,
                input: input,
                output: output,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead,
                dedupKey: dedupKey
            ))
        }

        let inferredProject = hintCounts
            .max(by: { $0.value < $1.value })?
            .key
        return (events, inferredProject)
    }

    // Placeholders that appear in SessionStart hook text / generic docs —
    // these would otherwise dominate sessions that don't mention a real project.
    private static let placeholderBlocklist: Set<String> = [
        "website-foo", "website-bar", "tool-foo", "website-name",
        "foo", "bar", "baz", "example", "project"
    ]

    private func extractProjectHints(from line: String) -> [String] {
        var hits: [String] = []
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        for rx in [websitesRegex, clientsRegex] {
            rx.enumerateMatches(in: line, range: range) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2,
                      let r = Range(m.range(at: 1), in: line) else { return }
                let name = String(line[r]).trimmingCharacters(in: .whitespaces)
                guard name.count >= 3,
                      !Self.placeholderBlocklist.contains(name.lowercased()) else { return }
                hits.append(name)
            }
        }
        return hits
    }

    private func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }

    private func buildBlocks(events: [RawEvent]) -> [UsageBlock] {
        var blocks: [UsageBlock] = []
        var currentStart: Date? = nil
        var currentEvents: [RawEvent] = []

        func flush() {
            guard let start = currentStart, !currentEvents.isEmpty else {
                currentStart = nil
                currentEvents.removeAll()
                return
            }
            let end = start.addingTimeInterval(blockDuration)
            let last = currentEvents.last!.timestamp
            let isActive = Date().timeIntervalSince(last) < blockDuration && Date() < end
            var tokens = TokenCounts()
            var cost = 0.0
            var modelsSet = Set<String>()
            for e in currentEvents {
                tokens.inputTokens += e.input
                tokens.outputTokens += e.output
                tokens.cacheCreationInputTokens += e.cacheCreation
                tokens.cacheReadInputTokens += e.cacheRead
                cost += Pricing.price(for: e.model).cost(
                    input: e.input, output: e.output,
                    cacheCreation: e.cacheCreation, cacheRead: e.cacheRead
                )
                modelsSet.insert(e.model)
            }
            var burn: BurnRate? = nil
            var proj: Projection? = nil
            let elapsed = last.timeIntervalSince(start)
            if isActive, elapsed > 60 {
                let minutes = elapsed / 60.0
                let tpm = Double(tokens.totalTokens) / minutes
                let cph = cost / (elapsed / 3600.0)
                burn = BurnRate(tokensPerMinute: tpm, costPerHour: cph)
                let remainingSec = max(0, end.timeIntervalSince(Date()))
                let remainingMin = Int(remainingSec / 60)
                let projectedExtraCost = cph * (remainingSec / 3600.0)
                let projectedExtraTokens = Int(tpm * (remainingSec / 60.0))
                proj = Projection(
                    totalCost: cost + projectedExtraCost,
                    totalTokens: tokens.totalTokens + projectedExtraTokens,
                    remainingMinutes: remainingMin
                )
            }
            let id = Self.iso8601Short(start)
            blocks.append(UsageBlock(
                id: id, startTime: start, endTime: end, lastActivity: last,
                isActive: isActive, tokens: tokens, costUSD: cost,
                models: Array(modelsSet).sorted(), burnRate: burn, projection: proj
            ))
            currentStart = nil
            currentEvents.removeAll()
        }

        for e in events {
            if let start = currentStart,
               let lastTs = currentEvents.last?.timestamp {
                let sinceStart = e.timestamp.timeIntervalSince(start)
                let sinceLast = e.timestamp.timeIntervalSince(lastTs)
                if sinceStart >= blockDuration || sinceLast >= blockDuration {
                    flush()
                    currentStart = floorToHour(e.timestamp)
                }
            } else {
                currentStart = floorToHour(e.timestamp)
            }
            currentEvents.append(e)
        }
        flush()
        return blocks
    }

    private func floorToHour(_ d: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: d)
        return cal.date(from: comps) ?? d
    }

    private func buildDaily(events: [RawEvent]) -> [DailyEntry] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current

        struct Bucket {
            var tokens = TokenCounts()
            var cost = 0.0
            var models: Set<String> = []
        }
        var buckets: [String: Bucket] = [:]
        for e in events {
            let key = fmt.string(from: e.timestamp)
            var b = buckets[key] ?? Bucket()
            b.tokens.inputTokens += e.input
            b.tokens.outputTokens += e.output
            b.tokens.cacheCreationInputTokens += e.cacheCreation
            b.tokens.cacheReadInputTokens += e.cacheRead
            b.cost += Pricing.price(for: e.model).cost(
                input: e.input, output: e.output,
                cacheCreation: e.cacheCreation, cacheRead: e.cacheRead
            )
            b.models.insert(e.model)
            buckets[key] = b
        }
        let sorted = buckets.keys.sorted(by: >)
        return sorted.map { date in
            let b = buckets[date]!
            return DailyEntry(date: date, tokens: b.tokens, costUSD: b.cost, models: Array(b.models).sorted())
        }
    }

    private func buildSessions(events: [RawEvent]) -> [SessionEntry] {
        struct Bucket {
            var projectPath: String = ""
            var start: Date = .distantFuture
            var last: Date = .distantPast
            var tokens = TokenCounts()
            var cost = 0.0
            var models: Set<String> = []
            var messages = 0
        }
        var buckets: [String: Bucket] = [:]
        for e in events {
            var b = buckets[e.sessionId] ?? Bucket()
            if b.projectPath.isEmpty { b.projectPath = e.projectPath }
            if e.timestamp < b.start { b.start = e.timestamp }
            if e.timestamp > b.last { b.last = e.timestamp }
            b.tokens.inputTokens += e.input
            b.tokens.outputTokens += e.output
            b.tokens.cacheCreationInputTokens += e.cacheCreation
            b.tokens.cacheReadInputTokens += e.cacheRead
            b.cost += Pricing.price(for: e.model).cost(
                input: e.input, output: e.output,
                cacheCreation: e.cacheCreation, cacheRead: e.cacheRead
            )
            b.models.insert(e.model)
            b.messages += 1
            buckets[e.sessionId] = b
        }
        return buckets.map { (sid, b) in
            SessionEntry(
                sessionId: sid, projectPath: b.projectPath,
                inferredProject: sessionHints[sid],
                startTime: b.start, lastActivity: b.last,
                tokens: b.tokens, costUSD: b.cost,
                models: Array(b.models).sorted(), messageCount: b.messages
            )
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func buildModelsForToday(events: [RawEvent]) -> [ModelUsage] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        let today = fmt.string(from: Date())

        struct Bucket { var tokens = TokenCounts(); var cost = 0.0 }
        var buckets: [String: Bucket] = [:]
        for e in events where fmt.string(from: e.timestamp) == today {
            var b = buckets[e.model] ?? Bucket()
            b.tokens.inputTokens += e.input
            b.tokens.outputTokens += e.output
            b.tokens.cacheCreationInputTokens += e.cacheCreation
            b.tokens.cacheReadInputTokens += e.cacheRead
            b.cost += Pricing.price(for: e.model).cost(
                input: e.input, output: e.output,
                cacheCreation: e.cacheCreation, cacheRead: e.cacheRead
            )
            buckets[e.model] = b
        }
        return buckets.map { (m, b) in
            ModelUsage(model: m, tokens: b.tokens, costUSD: b.cost)
        }.sorted { $0.costUSD > $1.costUSD }
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }

    private static func iso8601Short(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    private static func globJSONLFiles(root: URL) -> [URL]? {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var out: [URL] = []
        for dir in projects {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for f in files where f.pathExtension == "jsonl" {
                out.append(f)
            }
        }
        return out
    }

    private static func decodeProjectFolder(_ encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }
}
