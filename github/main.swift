import AppKit
import Combine
import SwiftUI

// MARK: - Data model

struct GHItem: Codable, Identifiable {
    struct PullRequestRef: Codable {
        let url: String?
    }

    let id: Int
    let number: Int
    let title: String
    let htmlUrl: String
    let updatedAt: Date?
    let comments: Int?
    let repositoryUrl: String
    let draft: Bool?
    let pullRequest: PullRequestRef?

    var isPullRequest: Bool { pullRequest != nil }
    var isDraft: Bool { draft ?? false }

    /// "owner/repo" from the API URL (…/repos/owner/repo).
    var repoFullName: String {
        guard let range = repositoryUrl.range(of: "/repos/") else { return "" }
        return String(repositoryUrl[range.upperBound...])
    }

    var repoName: String {
        repoFullName.components(separatedBy: "/").last ?? repoFullName
    }

    var link: URL? { URL(string: htmlUrl) }
}

struct SearchResponse: Codable {
    let totalCount: Int
    let items: [GHItem]
}

enum WidgetError: Error {
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized
    case noToken
    case http(Int)
    case badResponse

    var message: String {
        switch self {
        case .rateLimited: return "Rate limited — retrying later"
        case .unauthorized: return "GitHub token rejected (401)"
        case .noToken: return "No GitHub token in keychain"
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
        return dir.appendingPathComponent("GitHubWidget.log")
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

// MARK: - Token

enum GitHubAuth {
    private static var cached: String?

    /// Reads the github.com credential git already stores in the macOS keychain,
    /// so the widget needs no config of its own.
    static func token() throws -> String {
        if let cached { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["credential", "fill"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data("protocol=https\nhost=github.com\n\n".utf8))
        stdin.fileHandleForWriting.closeFile()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { throw WidgetError.noToken }
        for line in output.split(separator: "\n") where line.hasPrefix("password=") {
            let token = String(line.dropFirst("password=".count))
            if !token.isEmpty {
                cached = token
                return token
            }
        }
        throw WidgetError.noToken
    }

    static func invalidate() { cached = nil }
}

// MARK: - Fetching

final class GitHubModel: ObservableObject {
    @Published var items: [GHItem] = []
    @Published var totalCount = 0
    @Published var page = 0
    @Published var errorMessage: String?
    @Published var updatedAt: Date?
    @Published var isRefreshing = false

    static let pageSize = 4
    /// How many items we fetch (pageSize × number of pages).
    private static let itemCount = 28

    private var timer: Timer?

    /// Issue/PR activity is worth checking often; the search API allows
    /// 30 requests/min, so every 5 minutes is comfortably within limits.
    private static let pollInterval: TimeInterval = 300
    private static let retryInterval: TimeInterval = 120
    private var nextAttempt: Date = .distantPast
    private var backoff: TimeInterval = 0

    var pageCount: Int {
        max(1, (items.count + Self.pageSize - 1) / Self.pageSize)
    }

    var visibleItems: [GHItem] {
        let start = page * Self.pageSize
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + Self.pageSize, items.count)])
    }

    func start() {
        WidgetLog.write("Widget started (poll interval \(Int(Self.pollInterval))s)")
        loadCache()
        refresh()
        // The timer just ticks; nextAttempt decides whether a request actually fires.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func previousPage() {
        if page > 0 { page -= 1 }
    }

    func nextPage() {
        if page < pageCount - 1 { page += 1 }
    }

    /// `force` (manual refresh) bypasses the schedule.
    func refresh(force: Bool = false) {
        guard force || Date() >= nextAttempt else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        // Guard against overlapping attempts until this one resolves.
        nextAttempt = Date().addingTimeInterval(Self.pollInterval)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let response = try Self.fetchInvolvedItems()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.items = response.items
                    self.totalCount = response.totalCount
                    self.page = min(self.page, self.pageCount - 1)
                    if self.errorMessage != nil {
                        WidgetLog.write("Recovered — \(response.items.count) items fetched")
                    }
                    self.errorMessage = nil
                    self.updatedAt = Date()
                    self.backoff = 0
                    self.nextAttempt = Date().addingTimeInterval(Self.pollInterval)
                    if let data = try? JSONEncoder().encode(response.items) {
                        UserDefaults.standard.set(data, forKey: "cachedItems")
                        UserDefaults.standard.set(response.totalCount, forKey: "cachedTotalCount")
                        UserDefaults.standard.set(Date(), forKey: "cachedItemsDate")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    let widgetError = error as? WidgetError
                    // Keep showing the last known data; just note the failure.
                    self.errorMessage = widgetError?.message ?? error.localizedDescription

                    var wait = Self.retryInterval
                    if case .rateLimited(let retryAfter) = widgetError {
                        self.backoff = min(max(self.backoff * 2, 600), 3600)
                        wait = max(retryAfter ?? 0, self.backoff)
                    }
                    if case .unauthorized = widgetError {
                        // A rotated token may have landed in the keychain since.
                        GitHubAuth.invalidate()
                    }
                    self.nextAttempt = Date().addingTimeInterval(wait)
                    WidgetLog.write("Fetch failed: \(self.errorMessage ?? "unknown") — next attempt in \(Int(wait))s")
                }
            }
        }
    }

    /// Show the last successful response while the first fetch (or a backoff) is pending.
    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: "cachedItems"),
              let cached = try? JSONDecoder().decode([GHItem].self, from: data)
        else { return }
        items = cached
        totalCount = UserDefaults.standard.integer(forKey: "cachedTotalCount")
        updatedAt = UserDefaults.standard.object(forKey: "cachedItemsDate") as? Date
    }

    private static func fetchInvolvedItems() throws -> SearchResponse {
        // `involves:@me` covers author, assignee, mentions, and review requests.
        let query = "is:open involves:@me"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.github.com/search/issues"
            + "?q=\(query)&advanced_search=true&sort=updated&order=desc&per_page=\(itemCount)"
        guard let url = URL(string: urlString) else { throw WidgetError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(try GitHubAuth.token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitHubWidget", forHTTPHeaderField: "User-Agent")

        let (data, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse else { throw WidgetError.badResponse }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw WidgetError.unauthorized
        case 403, 429:
            // GitHub signals rate limits with either status; prefer Retry-After,
            // fall back to the rate-limit reset timestamp.
            var retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            if retryAfter == nil,
               let reset = (http.value(forHTTPHeaderField: "X-RateLimit-Reset")).flatMap(TimeInterval.init) {
                retryAfter = max(0, reset - Date().timeIntervalSince1970)
            }
            throw WidgetError.rateLimited(retryAfter: retryAfter)
        default:
            throw WidgetError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SearchResponse.self, from: data)
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

private let ghOpenGreen = Color(red: 0.10, green: 0.50, blue: 0.22) // #1a7f37
private let ghDraftGray = Color(red: 0.35, green: 0.38, blue: 0.42)

private func relativeText(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
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

struct ItemRow: View {
    let item: GHItem
    @State private var hovering = false

    var body: some View {
        Button {
            if let link = item.link {
                NSWorkspace.shared.open(link)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.isPullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.isDraft ? ghDraftGray : ghOpenGreen)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(hovering ? Color.accentColor : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(metaText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(item.repoFullName)#\(item.number) — \(item.title)")
        // Fixed height keeps the widget from jumping as pages change.
        .frame(height: 46, alignment: .top)
        .contextMenu {
            Button("Open on GitHub") {
                if let link = item.link { NSWorkspace.shared.open(link) }
            }
            Button("Open Repository") {
                if let url = URL(string: "https://github.com/\(item.repoFullName)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var metaText: String {
        var parts: [String] = ["\(item.repoName)#\(item.number)"]
        if item.isDraft { parts.append("draft") }
        if let comments = item.comments, comments > 0 {
            parts.append("\(comments) comment\(comments == 1 ? "" : "s")")
        }
        let time = relativeText(item.updatedAt)
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

struct WidgetView: View {
    @ObservedObject var model: GitHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            content
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        // Same width as the other widgets.
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
            Button("Open GitHub Issues") {
                NSWorkspace.shared.open(URL(string: "https://github.com/issues?q=is%3Aopen+involves%3A%40me")!)
            }
            Button("Open Log") { NSWorkspace.shared.open(WidgetLog.url) }
            Divider()
            WidgetChromeMenu()
            Divider()
            Button("Quit GitHub Widget") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.85)))
            SectionHeader(text: "GitHub — Involving Me")
            Spacer()
            if model.totalCount > 0 {
                Text("\(model.totalCount) open")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
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
                .help("Refresh now")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            if model.errorMessage == nil {
                Text(model.updatedAt == nil ? "Loading…" : "No open issues or PRs involve you 🎉")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.visibleItems) { item in
                    ItemRow(item: item)
                }
            }
            pager
        }
    }

    private var pager: some View {
        HStack(spacing: 10) {
            Button {
                model.previousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.page > 0 ? Color.primary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(model.page == 0)

            Text("\(model.page + 1) / \(model.pageCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.nextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.page < model.pageCount - 1 ? Color.primary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(model.page == model.pageCount - 1)

            Spacer()

            if let updatedAt = model.updatedAt {
                Text("Updated \(relativeText(updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
    private let model = GitHubModel()
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
        // Window level, desktop pinning, snapping, and arrange-all live in
        // shared/WidgetChrome.swift, compiled into every widget.
        WidgetChrome.shared.adopt(window)
        window.contentView = hosting

        if !window.setFrameUsingName("GitHubWidget") {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                // Default below where the Hacker News widget sits.
                window.setFrameTopLeftPoint(NSPoint(x: frame.minX + WidgetChrome.margin,
                                                    y: frame.maxY - 720))
            }
        }
        // A saved frame may predate a size change; snap back to the content's
        // size, keeping the top-left corner where the user put it.
        if abs(window.frame.size.width - hosting.fittingSize.width) > 1
            || abs(window.frame.size.height - hosting.fittingSize.height) > 1 {
            var frame = window.frame
            frame.origin.y += frame.height - hosting.fittingSize.height
            frame.size = hosting.fittingSize
            window.setFrame(frame, display: true)
        }
        window.setFrameAutosaveName("GitHubWidget")
        window.orderFrontRegardless()

        // Resize the window when the content height changes.
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
