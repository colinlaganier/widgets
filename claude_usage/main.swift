import AppKit
import Combine
import SwiftUI

// MARK: - Data model

struct UsageLimit: Decodable, Identifiable {
    struct Scope: Decodable {
        struct ModelInfo: Decodable { let displayName: String? }
        let model: ModelInfo?
    }

    let kind: String
    let group: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    let scope: Scope?

    var id: String { kind + (scope?.model?.displayName ?? "") }

    var label: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "All models"
        default: return scope?.model?.displayName ?? "Model"
        }
    }
}

struct UsageResponse: Decodable {
    let limits: [UsageLimit]
}

enum WidgetError: Error {
    case noCredentials
    case authExpired
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse

    var message: String {
        switch self {
        case .noCredentials: return "No Claude Code credentials found"
        case .authExpired: return "Auth expired — open Claude Code"
        case .rateLimited: return "Rate limited — retrying later"
        case .http(let code): return "Request failed (HTTP \(code))"
        case .badResponse: return "Unexpected response"
        }
    }
}

// MARK: - Logging

enum WidgetLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ClaudeUsageWidget.log")
    }()

    private static let queue = DispatchQueue(label: "widget.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "[\(stamp.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Fetching

final class UsageModel: ObservableObject {
    @Published var session: UsageLimit?
    @Published var weekly: [UsageLimit] = []
    @Published var errorMessage: String?
    @Published var updatedAt: Date?
    @Published var isRefreshing = false

    private var timer: Timer?

    /// Base poll interval. The endpoint rate-limits aggressively, so stay gentle.
    private static let pollInterval: TimeInterval = 300
    private var nextAttempt: Date = .distantPast
    private var backoff: TimeInterval = 0

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func start() {
        WidgetLog.write("Widget started (poll interval \(Int(Self.pollInterval))s)")
        loadCache()
        refresh()
        // The timer just ticks; nextAttempt decides whether a request actually fires.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// `force` (manual refresh from the context menu) bypasses the schedule.
    func refresh(force: Bool = false) {
        guard force || Date() >= nextAttempt else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        // Guard against overlapping attempts until this one resolves.
        nextAttempt = Date().addingTimeInterval(Self.pollInterval)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let (usage, rawData) = try Self.fetchUsage()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.apply(usage)
                    if self.errorMessage != nil {
                        WidgetLog.write("Recovered — usage fetched successfully")
                    }
                    self.errorMessage = nil
                    self.updatedAt = Date()
                    self.backoff = 0
                    self.nextAttempt = Date().addingTimeInterval(Self.pollInterval)
                    UserDefaults.standard.set(rawData, forKey: "cachedUsage")
                    UserDefaults.standard.set(Date(), forKey: "cachedUsageDate")
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    let widgetError = error as? WidgetError
                    // Keep showing the last known data; just note the failure.
                    self.errorMessage = widgetError?.message ?? error.localizedDescription

                    var wait = Self.pollInterval
                    if case .rateLimited(let retryAfter) = widgetError {
                        // Exponential backoff: 10 min, 20 min, ... capped at 1 h,
                        // never less than the server's Retry-After.
                        self.backoff = min(max(self.backoff * 2, 600), 3600)
                        wait = max(retryAfter ?? 0, self.backoff)
                    }
                    self.nextAttempt = Date().addingTimeInterval(wait)
                    WidgetLog.write("Fetch failed: \(self.errorMessage ?? "unknown") — next attempt in \(Int(wait))s")
                }
            }
        }
    }

    private func apply(_ usage: UsageResponse) {
        session = usage.limits.first { $0.group == "session" }
        weekly = usage.limits.filter { $0.group == "weekly" }
    }

    /// Show the last successful response while the first fetch (or a backoff) is pending.
    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: "cachedUsage"),
              let usage = try? Self.decode(data)
        else { return }
        apply(usage)
        updatedAt = UserDefaults.standard.object(forKey: "cachedUsageDate") as? Date
    }

    private static func fetchUsage() throws -> (UsageResponse, Data) {
        let token = try accessToken()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse else { throw WidgetError.badResponse }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw WidgetError.authExpired
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw WidgetError.rateLimited(retryAfter: retryAfter)
        default:
            throw WidgetError.http(http.statusCode)
        }

        return (try decode(data), data)
    }

    private static func decode(_ data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return try decoder.decode(UsageResponse.self, from: data)
    }

    private static func accessToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw WidgetError.noCredentials }
        return token
    }

    private static func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = result.2 { throw error }
        guard let data = result.0, let response = result.1 else { throw WidgetError.badResponse }
        return (data, response)
    }
}

// MARK: - Views

private let claudeCoral = Color(red: 0.85, green: 0.47, blue: 0.34)

private func usageTint(for percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .orange }
    return claudeCoral
}

private func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    if Calendar.current.isDateInToday(date) {
        f.timeStyle = .short
        f.dateStyle = .none
    } else {
        f.setLocalizedDateFormatFromTemplate("EEE j:mm")
    }
    return "Resets \(f.string(from: date))"
}

struct UsageBar: View {
    let percent: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(usageTint(for: percent))
                    .frame(width: max(height, geo.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: height)
    }
}

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct WidgetView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sessionSection
                .frame(width: 128, alignment: .leading)
            Divider()
            weeklySection
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .contextMenu {
            Button("Refresh") { model.refresh(force: true) }
            Button("Open Log") { NSWorkspace.shared.open(WidgetLog.url) }
            Divider()
            Button("Quit Claude Usage") { NSApp.terminate(nil) }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(text: "Session")
            if let session = model.session {
                Text("\(Int(session.percent))%")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.primary)
                UsageBar(percent: session.percent)
                Text(resetText(session.resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tertiary)
                UsageBar(percent: 0)
            }
        }
    }

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(text: "Weekly limits")
                Spacer()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Button {
                        model.refresh(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh usage now")
                }
            }
            if model.weekly.isEmpty {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            } else {
                ForEach(model.weekly) { limit in
                    HStack(spacing: 8) {
                        Text(limit.label)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .frame(width: 84, alignment: .leading)
                            .lineLimit(1)
                        UsageBar(percent: limit.percent)
                        Text("\(Int(limit.percent))%")
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                if let reset = model.weekly.compactMap(\.resetsAt).min() {
                    Text(resetText(reset))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - App

/// Borderless windows refuse key status by default, which blocks clicks,
/// dragging, and context menus — opt back in.
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = UsageModel()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: WidgetView(model: model))
        hosting.setFrameSize(hosting.fittingSize)

        window = WidgetWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        // One step above Finder's desktop icons (which would otherwise cover the
        // widget and swallow clicks), still below normal app windows.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = hosting

        if !window.setFrameUsingName("ClaudeUsageWidget") {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - hosting.fittingSize.width - 24,
                                                    y: frame.maxY - 24))
            }
        }
        window.setFrameAutosaveName("ClaudeUsageWidget")
        window.orderFrontRegardless()

        // Resize the window when the number of weekly rows changes.
        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let hosting = self.window.contentView else { return }
                    let size = hosting.fittingSize
                    if abs(size.height - self.window.frame.height) > 1 {
                        var frame = self.window.frame
                        frame.origin.y += frame.height - size.height
                        frame.size = size
                        self.window.setFrame(frame, display: true, animate: false)
                    }
                }
            }

        model.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
