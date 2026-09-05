import Foundation
import Darwin
import CryptoKit

enum SubscriptionProvider: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}

struct SubscriptionWindow {
    let usedPercent: Double
    let resetsAt: Date?
    let durationMinutes: Int

    func countdown(at now: Date = Date()) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds.isFinite, abs(seconds) < 315_576_000 else { return "Reset time unavailable" }
        guard seconds > 0 else { return "Awaiting reset update" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

struct SubscriptionUsage {
    let provider: SubscriptionProvider
    let weekly: SubscriptionWindow?
    let session: SubscriptionWindow?
    let fetchedAt: Date
    let error: String?
    let plan: String?
}

private enum SubscriptionError: Error {
    case credentials, keychain, unsupportedProfile, response, http(Int)
    var message: String {
        switch self {
        case .credentials: return "Open the CLI and sign in to read subscription usage."
        case .keychain: return "Claude credentials are unavailable from Keychain."
        case .unsupportedProfile: return "The selected Claude profile has no readable credentials."
        case .response: return "The provider returned no readable usage windows."
        case .http(401), .http(403): return "Session expired or access denied. Open the CLI to reconnect."
        case .http(429): return "Usage checks are rate limited. Try again later."
        case .http: return "The provider could not load usage. Try again later."
        }
    }
}

/// Read-only subscription requests using the existing CLI login. No refresh tokens,
/// login changes, credential persistence, telemetry, or paid model calls.
/// Endpoints follow claude-swap/oauth.py and openai/codex backend-client.
final class SubscriptionUsageService {
    private let home: URL
    private let environment: [String: String]
    private let session: URLSession
    private let backoffLock = NSLock()
    private var retryAfter: [SubscriptionProvider: Date] = [:]

    private func isBackingOff(_ provider: SubscriptionProvider) -> Bool {
        backoffLock.lock(); defer { backoffLock.unlock() }
        return (retryAfter[provider] ?? .distantPast) > Date()
    }

    private func backOff(_ provider: SubscriptionProvider) {
        backoffLock.lock(); defer { backoffLock.unlock() }
        retryAfter[provider] = Date().addingTimeInterval(300)
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         session: URLSession? = nil) {
        self.home = home
        self.environment = environment
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config, delegate: NoUsageRedirects(), delegateQueue: nil)
        }
    }

    func fetch(_ provider: SubscriptionProvider) async -> SubscriptionUsage {
        do {
            if isBackingOff(provider) { throw SubscriptionError.http(429) }
            let request = try makeRequest(provider)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SubscriptionError.response }
            guard response.statusCode == 200 else {
                if response.statusCode == 429 { backOff(provider) }
                throw SubscriptionError.http(response.statusCode)
            }
            return try Self.parse(data, provider: provider)
        } catch {
            let message = (error as? SubscriptionError)?.message
                ?? ((error as? URLError)?.code == .timedOut
                    ? "Usage check timed out. Try again later."
                    : "Usage is unavailable. Check your connection and try again.")
            return SubscriptionUsage(provider: provider, weekly: nil, session: nil,
                                     fetchedAt: Date(), error: message, plan: nil)
        }
    }

    private func makeRequest(_ provider: SubscriptionProvider) throws -> URLRequest {
        var request: URLRequest
        if provider == .claude {
            let data = try claudeCredentials()
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { throw SubscriptionError.credentials }
            request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = json["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String, !token.isEmpty else { throw SubscriptionError.credentials }
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let account = tokens["account_id"] as? String, !account.isEmpty {
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }
        request.assumesHTTP3Capable = false
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("RelayBar/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func claudeCredentials() throws -> Data {
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] ?? config ?? ""
        var services = ["Claude Code-credentials"]
        if !secure.isEmpty {
            let hash = SHA256.hash(data: Data(secure.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
            services = ["Claude Code-credentials-\(hash.prefix(8))"]
        }
        for service in services {
            if let data = Self.keychainCredential(service: service) { return data }
        }
        // Claude's file fallback is read only; the active Keychain always wins.
        let directory = config.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        if let data = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json")) { return data }
        throw secure.isEmpty ? SubscriptionError.keychain : SubscriptionError.unsupportedProfile
    }

    /// Use Apple's already trusted helper. A new unsigned app cannot directly read
    /// Claude's legacy Keychain ACL. Never change that ACL or persist returned bytes.
    private static func keychainCredential(service: String) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        // Drain concurrently so a large Keychain item cannot fill the pipe and hang.
        let reader = CredentialReadBuffer()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            reader.store(pipe.fileHandleForReading.readDataToEndOfFile())
            readDone.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
              readDone.wait(timeout: .now() + 1) == .success else { return nil }
        return reader.load()
    }

    static func parse(_ data: Data, provider: SubscriptionProvider, now: Date = Date()) throws -> SubscriptionUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SubscriptionError.response }
        var weekly: SubscriptionWindow?
        var session: SubscriptionWindow?
        if provider == .claude {
            weekly = claudeWindow(root["seven_day"], minutes: 10080)
            session = claudeWindow(root["five_hour"], minutes: 300)
        } else if let limits = root["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let value = limits[key] as? [String: Any],
                      let used = finiteNumber(value["used_percent"]),
                      let seconds = finiteNumber(value["limit_window_seconds"]), seconds > 0, seconds < 31_557_600 else { continue }
                let reset = finiteNumber(value["reset_at"]).map(Date.init(timeIntervalSince1970:))
                let window = SubscriptionWindow(usedPercent: min(100, max(0, used)), resetsAt: reset, durationMinutes: Int(seconds / 60))
                if window.durationMinutes == 10080 { weekly = window }
                else if window.durationMinutes < 1440 { session = window }
            }
        }
        guard weekly != nil || session != nil else { throw SubscriptionError.response }
        return SubscriptionUsage(provider: provider, weekly: weekly, session: session, fetchedAt: now,
                                 error: nil, plan: root["plan_type"] as? String)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func claudeWindow(_ value: Any?, minutes: Int) -> SubscriptionWindow? {
        guard let value = value as? [String: Any], let used = finiteNumber(value["utilization"]) else { return nil }
        var reset: Date?
        if let string = value["resets_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = formatter.date(from: string)
            if reset == nil {
                formatter.formatOptions = [.withInternetDateTime]
                reset = formatter.date(from: string)
            }
        }
        return SubscriptionWindow(usedPercent: min(100, max(0, used)), resetsAt: reset, durationMinutes: minutes)
    }
}

private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class CredentialReadBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func store(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data = value.count <= 1_048_576 ? value : nil
    }
    func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
