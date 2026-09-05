/*
Codex JSONL schema adapted from SpendBar CodexSessionParser.
MIT License

Copyright (c) 2026 Flavio Adamo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
import Foundation
import Darwin

/// Local Codex usage only. Costs are unavailable (zero); quota windows come from
/// account usage, never a guessed five-hour window derived from these events.
final class CodexTranscriptParser {
    static let shared = CodexTranscriptParser()

    private struct Sample {
        let timestamp: Date
        let session: String
        let cwd: String
        let model: String
        let input: Int
        let cached: Int
        let output: Int
    }
    private struct Event {
        let sample: Sample
        let tokens: TokenCounts
    }
    private struct CachedFile {
        let modified: Date
        let size: Int
        let samples: [Sample]
    }

    private let roots: [URL]
    private let now: () -> Date
    private let calendar: Calendar
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    private var cache: [String: CachedFile] = [:]

    init(roots: [URL]? = nil, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.roots = roots ?? [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        self.now = now
        self.calendar = calendar
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func snapshot() -> UsageSnapshot {
        let current = now()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: current)
        let start = calendar.startOfDay(for: current)
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: start) ?? start
        let cutoff = formatter.string(from: thirtyDaysAgo)
        let events = loadEvents().filter { $0.sample.timestamp <= current }
        var days: [String: DailyEntry] = [:]
        var sessions: [String: SessionEntry] = [:]
        var models: [String: ModelUsage] = [:]
        for event in events {
            let sample = event.sample
            let day = formatter.string(from: sample.timestamp)
            var daily = days[day] ?? DailyEntry(date: day, tokens: TokenCounts(), costUSD: 0, models: [])
            daily.tokens += event.tokens
            daily.models = Array(Set(daily.models + [sample.model])).sorted()
            days[day] = daily
            let previous = sessions[sample.session]
            sessions[sample.session] = SessionEntry(
                sessionId: sample.session, projectPath: sample.cwd, inferredProject: nil,
                startTime: previous?.startTime ?? sample.timestamp, lastActivity: sample.timestamp,
                tokens: (previous?.tokens ?? TokenCounts()) + event.tokens, costUSD: 0,
                models: Array(Set((previous?.models ?? []) + [sample.model])).sorted(),
                messageCount: (previous?.messageCount ?? 0) + 1)
            if day == todayKey {
                var model = models[sample.model] ?? ModelUsage(model: sample.model, tokens: TokenCounts(), costUSD: 0)
                model.tokens += event.tokens
                models[sample.model] = model
            }
        }
        let daily = days.values.sorted { $0.date > $1.date }
        return UsageSnapshot(
            activeBlock: nil, today: days[todayKey], daily: daily,
            sessions: sessions.values.sorted { $0.lastActivity > $1.lastActivity },
            modelsToday: models.values.sorted { $0.tokens.totalTokens > $1.tokens.totalTokens },
            last7DaysCost: 0, last30DaysCost: 0,
            last30DaysTokens: daily.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.totalTokens },
            monthCost: 0, allTimeTokens: daily.reduce(0) { $0 + $1.totalTokens },
            allTimeCost: 0, activeDays: daily.count, firstActiveDate: daily.last?.date)
    }

    private func loadEvents() -> [Event] {
        var samples: [Sample] = []
        var live = Set<String>()
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard live.insert(url.path).inserted,
                      let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                      attributes.isRegularFile == true else { continue }
                let modified = attributes.contentModificationDate ?? .distantPast
                let size = attributes.fileSize ?? 0
                if let cached = cache[url.path], cached.modified == modified, cached.size == size {
                    samples += cached.samples
                } else {
                    let parsed = parse(url)
                    cache[url.path] = CachedFile(modified: modified, size: size, samples: parsed)
                    samples += parsed
                }
            }
        }
        cache = cache.filter { live.contains($0.key) }
        // Merge all copies before computing deltas. Replayed cumulative snapshots,
        // resumed files and archived duplicates must never add usage a second time.
        let grouped = Dictionary(grouping: samples, by: \.session)
        var events: [Event] = []
        for group in grouped.values {
            var input = 0, cached = 0, output = 0
            for sample in group.sorted(by: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.input != $1.input { return $0.input < $1.input }
                return $0.output < $1.output
            }) {
                let deltaInput = max(0, sample.input - input)
                let deltaCached = min(deltaInput, max(0, sample.cached - cached))
                let deltaOutput = max(0, sample.output - output)
                input = max(input, sample.input)
                cached = max(cached, sample.cached)
                output = max(output, sample.output)
                guard deltaInput + deltaOutput > 0 else { continue }
                // OpenAI cached input is a subset of input, reasoning a subset of
                // output. Match TokenCounts' separate cache bucket without doubling.
                events.append(Event(sample: sample, tokens: TokenCounts(
                    inputTokens: deltaInput - deltaCached, outputTokens: deltaOutput,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: deltaCached)))
            }
        }
        return events.sorted { $0.sample.timestamp < $1.sample.timestamp }
    }

    private func parse(_ url: URL) -> [Sample] {
        guard let contents = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
        var session = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var model = "Unknown Codex model"
        var samples: [Sample] = []
        func consume(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }
            if type == "session_meta" {
                session = payload["id"] as? String ?? session
                cwd = payload["cwd"] as? String ?? cwd
            } else if type == "turn_context" {
                cwd = payload["cwd"] as? String ?? cwd
                model = payload["model"] as? String ?? model
            } else if type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let timestamp = object["timestamp"] as? String,
                      let date = self.fractional.date(from: timestamp) ?? self.plain.date(from: timestamp) {
                samples.append(Sample(timestamp: date, session: session, cwd: cwd, model: model,
                    input: max(0, total["input_tokens"] as? Int ?? 0),
                    cached: max(0, total["cached_input_tokens"] as? Int ?? 0),
                    output: max(0, total["output_tokens"] as? Int ?? 0)))
            }
        }
        // Scan bytes first. Transcripts can be gigabytes; decoding user/tool bodies
        // into Swift strings dominates cold-start time and is unnecessary here.
        contents.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let newline = memchr(base.advanced(by: offset), 10, remaining)
                let end = newline.map { base.distance(to: $0) } ?? bytes.count
                let length = end - offset
                let line = base.advanced(by: offset)
                let prefixLength = min(length, 512)
                if memmem(line, prefixLength, "session_meta", 12) != nil
                    || memmem(line, prefixLength, "turn_context", 12) != nil
                    || memmem(line, prefixLength, "token_count", 11) != nil {
                    consume(Data(bytes: base.advanced(by: offset), count: length))
                }
                offset = end + 1
            }
        }
        return samples
    }
}
