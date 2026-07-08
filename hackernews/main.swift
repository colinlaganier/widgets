import AppKit
import Combine
import SwiftUI

// MARK: - Data model

struct HNStory: Codable, Identifiable {
    let id: Int
    let title: String
    let url: String?
    let score: Int?
    let by: String?
    let time: TimeInterval?
    let descendants: Int?

    var createdAt: Date? { time.map(Date.init(timeIntervalSince1970:)) }

    /// Ask HN / job posts have no external URL — fall back to the discussion page.
    var link: URL? {
        URL(string: url ?? "https://news.ycombinator.com/item?id=\(id)")
    }

    var commentsLink: URL? {
        URL(string: "https://news.ycombinator.com/item?id=\(id)")
    }
}

enum WidgetError: Error {
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse

    var message: String {
        switch self {
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
        return dir.appendingPathComponent("HackerNewsWidget.log")
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

final class HackerNewsModel: ObservableObject {
    @Published var stories: [HNStory] = []
    @Published var page = 0
    @Published var errorMessage: String?
    @Published var updatedAt: Date?
    @Published var isRefreshing = false

    static let pageSize = 3
    /// How deep into the front page we fetch (pageSize × number of pages).
    private static let storyCount = 15

    private var timer: Timer?

    /// Headlines don't move fast; refresh hourly.
    private static let pollInterval: TimeInterval = 3600
    /// After a failure, retry sooner than the full hour.
    private static let retryInterval: TimeInterval = 300
    private var nextAttempt: Date = .distantPast
    private var backoff: TimeInterval = 0

    var pageCount: Int {
        max(1, (stories.count + Self.pageSize - 1) / Self.pageSize)
    }

    var visibleStories: [(rank: Int, story: HNStory)] {
        let start = page * Self.pageSize
        guard start < stories.count else { return [] }
        let end = min(start + Self.pageSize, stories.count)
        return (start..<end).map { ($0 + 1, stories[$0]) }
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
                let stories = try Self.fetchTopStories()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.stories = stories
                    self.page = min(self.page, self.pageCount - 1)
                    if self.errorMessage != nil {
                        WidgetLog.write("Recovered — stories fetched successfully")
                    }
                    self.errorMessage = nil
                    self.updatedAt = Date()
                    self.backoff = 0
                    self.nextAttempt = Date().addingTimeInterval(Self.pollInterval)
                    if let data = try? JSONEncoder().encode(stories) {
                        UserDefaults.standard.set(data, forKey: "cachedStories")
                        UserDefaults.standard.set(Date(), forKey: "cachedStoriesDate")
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
                    self.nextAttempt = Date().addingTimeInterval(wait)
                    WidgetLog.write("Fetch failed: \(self.errorMessage ?? "unknown") — next attempt in \(Int(wait))s")
                }
            }
        }
    }

    /// Show the last successful response while the first fetch (or a backoff) is pending.
    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: "cachedStories"),
              let cached = try? JSONDecoder().decode([HNStory].self, from: data)
        else { return }
        stories = cached
        updatedAt = UserDefaults.standard.object(forKey: "cachedStoriesDate") as? Date
    }

    private static func fetchTopStories() throws -> [HNStory] {
        let ids = try fetch([Int].self, from: "https://hacker-news.firebaseio.com/v0/topstories.json")
        return try ids.prefix(storyCount).map { id in
            try fetch(HNStory.self, from: "https://hacker-news.firebaseio.com/v0/item/\(id).json")
        }
    }

    private static func fetch<T: Decodable>(_ type: T.Type, from urlString: String) throws -> T {
        guard let url = URL(string: urlString) else { throw WidgetError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse else { throw WidgetError.badResponse }
        switch http.statusCode {
        case 200:
            break
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw WidgetError.rateLimited(retryAfter: retryAfter)
        default:
            throw WidgetError.http(http.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
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

private let hnOrange = Color(red: 1.0, green: 0.4, blue: 0.0) // #ff6600

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

struct CommentsButton: View {
    let story: HNStory
    @State private var hovering = false

    var body: some View {
        Button {
            if let link = story.commentsLink {
                NSWorkspace.shared.open(link)
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open comments on Hacker News")
    }
}

struct StoryRow: View {
    let rank: Int
    let story: HNStory
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                if let link = story.link {
                    NSWorkspace.shared.open(link)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text("\(rank)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(hnOrange)
                        .frame(width: 16, alignment: .trailing)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(story.title)
                            .font(.callout)
                            .foregroundStyle(hovering ? hnOrange : .primary)
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
            .help(story.title)
            CommentsButton(story: story)
                .padding(.top, 1)
        }
        // Fixed height keeps the widget from jumping as pages change.
        .frame(height: 46, alignment: .top)
        .contextMenu {
            Button("Open Article") {
                if let link = story.link { NSWorkspace.shared.open(link) }
            }
            Button("Open Comments") {
                if let link = story.commentsLink { NSWorkspace.shared.open(link) }
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let score = story.score { parts.append("\(score) pts") }
        if let comments = story.descendants { parts.append("\(comments) comments") }
        let time = relativeText(story.createdAt)
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: " · ")
    }
}

struct WidgetView: View {
    @ObservedObject var model: HackerNewsModel

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
        // Same width as the Claude usage widget.
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
            Button("Open Hacker News") {
                NSWorkspace.shared.open(URL(string: "https://news.ycombinator.com")!)
            }
            Button("Open Log") { NSWorkspace.shared.open(WidgetLog.url) }
            Divider()
            WidgetChromeMenu()
            Divider()
            Button("Quit Hacker News Widget") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Y")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(hnOrange))
            SectionHeader(text: "Hacker News")
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
                .help("Refresh now")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.stories.isEmpty {
            if model.errorMessage == nil {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.visibleStories, id: \.story.id) { item in
                    StoryRow(rank: item.rank, story: item.story)
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
    private let model = HackerNewsModel()
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

        if !window.setFrameUsingName("HackerNewsWidget") {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                // Default below where the Claude usage and W&B widgets sit.
                window.setFrameTopLeftPoint(NSPoint(x: frame.minX + WidgetChrome.margin,
                                                    y: frame.maxY - 480))
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
        window.setFrameAutosaveName("HackerNewsWidget")
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
