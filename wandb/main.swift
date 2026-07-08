import AppKit
import Combine
import SwiftUI

// MARK: - Data model

struct WBRun: Decodable, Identifiable {
    struct User: Decodable { let username: String? }

    let name: String
    let displayName: String?
    let state: String
    let createdAt: Date?
    let heartbeatAt: Date?
    let user: User?

    var id: String { name }
    var title: String { displayName ?? name }
}

struct GQLError: Decodable { let message: String }

struct GQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GQLError]?
}

struct ViewerData: Decodable {
    struct Viewer: Decodable {
        let entity: String?
        let username: String?
    }
    let viewer: Viewer?
}

struct ProjectsData: Decodable {
    struct Models: Decodable {
        struct Edge: Decodable {
            struct Node: Decodable {
                let name: String
                /// Runs visible to this API key.
                let runCount: Int?
                /// All runs, including ones hidden by restricted-project permissions.
                let totalRuns: Int?
            }
            let node: Node
        }
        let edges: [Edge]
    }
    let models: Models?
}

struct RunsData: Decodable {
    struct Project: Decodable {
        struct Connection: Decodable {
            struct Edge: Decodable { let node: WBRun }
            let edges: [Edge]
        }
        let running: Connection?
        let latest: Connection?
    }
    let project: Project?
}

enum WidgetError: Error {
    case noAPIKey
    case authFailed
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case graphQL(String)
    case badResponse

    var message: String {
        switch self {
        case .noAPIKey: return "No W&B API key — run `wandb login`"
        case .authFailed: return "Auth failed — re-run `wandb login`"
        case .rateLimited: return "Rate limited — retrying later"
        case .http(let code): return "Request failed (HTTP \(code))"
        case .graphQL(let msg): return msg
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
        return dir.appendingPathComponent("WandbWidget.log")
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

final class WandbModel: ObservableObject {
    @Published var entity: String?
    @Published var projects: [String] = []
    @Published var selectedProject: String?
    @Published var runningRuns: [WBRun] = []
    @Published var latestRuns: [WBRun] = []
    @Published var errorMessage: String?
    @Published var updatedAt: Date?
    @Published var isRefreshing = false

    private var timer: Timer?

    private static let pollInterval: TimeInterval = 60
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
    /// W&B sometimes returns timestamps without a timezone suffix; they are UTC.
    private static let noZone: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func start() {
        WidgetLog.write("Widget started (poll interval \(Int(Self.pollInterval))s)")
        loadCache()
        refresh()
        // The timer just ticks; nextAttempt decides whether a request actually fires.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func select(project: String) {
        guard project != selectedProject else { return }
        selectedProject = project
        UserDefaults.standard.set(project, forKey: "selectedProject")
        runningRuns = []
        latestRuns = []
        loadRunsCache(for: project)
        refresh(force: true)
    }

    /// `force` (manual refresh or project switch) bypasses the schedule.
    func refresh(force: Bool = false) {
        guard force || Date() >= nextAttempt else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        nextAttempt = Date().addingTimeInterval(Self.pollInterval)

        let knownEntity = entity
        let requestedProject = selectedProject

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let apiKey = try Self.apiKey()

                let entity: String
                if let knownEntity {
                    entity = knownEntity
                } else {
                    entity = try Self.fetchEntity(apiKey: apiKey)
                }

                // Re-fetch every poll so new projects and permission changes show up.
                let projects = try Self.fetchProjects(entity: entity, apiKey: apiKey)

                let project = (requestedProject.flatMap { projects.contains($0) ? $0 : nil })
                    ?? projects.first

                var runsData: Data?
                if let project {
                    runsData = try Self.fetchRuns(entity: entity, project: project, apiKey: apiKey)
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.entity = entity
                    self.projects = projects
                    self.selectedProject = project
                    if self.errorMessage != nil {
                        WidgetLog.write("Recovered — fetch succeeded")
                    }
                    self.errorMessage = nil
                    self.updatedAt = Date()
                    self.backoff = 0
                    self.nextAttempt = Date().addingTimeInterval(Self.pollInterval)

                    UserDefaults.standard.set(entity, forKey: "entity")
                    UserDefaults.standard.set(projects, forKey: "projects")
                    if let project {
                        UserDefaults.standard.set(project, forKey: "selectedProject")
                    }
                    if let project, let runsData {
                        self.apply(runsData)
                        UserDefaults.standard.set(runsData, forKey: "cachedRuns:\(project)")
                        UserDefaults.standard.set(Date(), forKey: "cachedRunsDate:\(project)")
                    }
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
                        self.backoff = min(max(self.backoff * 2, 300), 3600)
                        wait = max(retryAfter ?? 0, self.backoff)
                    }
                    self.nextAttempt = Date().addingTimeInterval(wait)
                    WidgetLog.write("Fetch failed: \(self.errorMessage ?? "unknown") — next attempt in \(Int(wait))s")
                }
            }
        }
    }

    private func apply(_ runsData: Data) {
        guard let data = try? Self.decode(GQLResponse<RunsData>.self, from: runsData).data else { return }
        runningRuns = data.project?.running?.edges.map(\.node) ?? []
        latestRuns = data.project?.latest?.edges.map(\.node) ?? []
    }

    /// Show the last successful response while the first fetch (or a backoff) is pending.
    private func loadCache() {
        entity = UserDefaults.standard.string(forKey: "entity")
        projects = UserDefaults.standard.stringArray(forKey: "projects") ?? []
        selectedProject = UserDefaults.standard.string(forKey: "selectedProject") ?? projects.first
        if let project = selectedProject {
            loadRunsCache(for: project)
        }
    }

    private func loadRunsCache(for project: String) {
        guard let data = UserDefaults.standard.data(forKey: "cachedRuns:\(project)") else { return }
        apply(data)
        updatedAt = UserDefaults.standard.object(forKey: "cachedRunsDate:\(project)") as? Date
    }

    // MARK: GraphQL

    private static func fetchEntity(apiKey: String) throws -> String {
        let response = try graphQL(
            ViewerData.self,
            query: "query { viewer { entity username } }",
            variables: [:],
            apiKey: apiKey
        )
        guard let entity = response.viewer?.entity ?? response.viewer?.username else {
            throw WidgetError.authFailed
        }
        return entity
    }

    private static func fetchProjects(entity: String, apiKey: String) throws -> [String] {
        let response = try graphQL(
            ProjectsData.self,
            query: """
            query Projects($entity: String!) {
                models(entityName: $entity, first: 100) {
                    edges { node { name runCount totalRuns } }
                }
            }
            """,
            variables: ["entity": entity],
            apiKey: apiKey
        )
        let nodes = response.models?.edges.map(\.node) ?? []
        // Restricted projects still appear in the team list, but none of their
        // runs are visible: totalRuns counts everything, runCount only what
        // this API key can read. Keep genuinely empty projects (both zero).
        return nodes
            .filter { ($0.runCount ?? 0) > 0 || ($0.totalRuns ?? 0) == 0 }
            .map(\.name)
    }

    /// Returns the raw response data so it can double as the cache payload.
    private static func fetchRuns(entity: String, project: String, apiKey: String) throws -> Data {
        let query = """
        query Runs($entity: String!, $project: String!, $runningFilter: JSONString) {
            project(name: $project, entityName: $entity) {
                running: runs(first: 5, filters: $runningFilter, order: "-created_at") {
                    edges { node { name displayName state createdAt heartbeatAt user { username } } }
                }
                latest: runs(first: 5, order: "-created_at") {
                    edges { node { name displayName state createdAt heartbeatAt user { username } } }
                }
            }
        }
        """
        let data = try graphQLRaw(
            query: query,
            variables: ["entity": entity, "project": project, "runningFilter": "{\"state\":\"running\"}"],
            apiKey: apiKey
        )
        // Validate before returning so a GraphQL error never lands in the cache.
        let response = try decode(GQLResponse<RunsData>.self, from: data)
        if let message = response.errors?.first?.message {
            throw WidgetError.graphQL(message)
        }
        guard response.data?.project != nil else { throw WidgetError.badResponse }
        return data
    }

    private static func graphQL<T: Decodable>(
        _ type: T.Type, query: String, variables: [String: String], apiKey: String
    ) throws -> T {
        let data = try graphQLRaw(query: query, variables: variables, apiKey: apiKey)
        let response = try decode(GQLResponse<T>.self, from: data)
        if let message = response.errors?.first?.message {
            throw WidgetError.graphQL(message)
        }
        guard let payload = response.data else { throw WidgetError.badResponse }
        return payload
    }

    private static func graphQLRaw(
        query: String, variables: [String: String], apiKey: String
    ) throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.wandb.ai/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credentials = Data("api:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables,
        ])
        request.timeoutInterval = 15

        let (data, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse else { throw WidgetError.badResponse }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw WidgetError.authFailed
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw WidgetError.rateLimited(retryAfter: retryAfter)
        default:
            throw WidgetError.http(http.statusCode)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) ?? noZone.date(from: s) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return try decoder.decode(type, from: data)
    }

    private static func apiKey() throws -> String {
        if let key = ProcessInfo.processInfo.environment["WANDB_API_KEY"], !key.isEmpty {
            return key
        }
        let netrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".netrc")
        guard let text = try? String(contentsOf: netrc, encoding: .utf8) else {
            throw WidgetError.noAPIKey
        }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var inWandbMachine = false
        var index = 0
        while index < tokens.count {
            if tokens[index] == "machine", index + 1 < tokens.count {
                inWandbMachine = tokens[index + 1].contains("wandb.ai")
                index += 2
                continue
            }
            if inWandbMachine, tokens[index] == "password", index + 1 < tokens.count {
                return tokens[index + 1]
            }
            index += 1
        }
        throw WidgetError.noAPIKey
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

private let wandbGold = Color(red: 1.0, green: 0.788, blue: 0.2) // #ffc933
private let runningGreen = Color(red: 0.22, green: 0.72, blue: 0.42)

private func stateColor(_ state: String) -> Color {
    switch state {
    case "running": return runningGreen
    case "finished": return runningGreen
    case "crashed", "failed": return .red
    case "killed": return .orange
    default: return .secondary
    }
}

private func relativeText(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}

private func elapsedText(since start: Date?) -> String {
    guard let start else { return "" }
    let seconds = max(0, Int(Date().timeIntervalSince(start)))
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
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

struct StatePill: View {
    let state: String

    var body: some View {
        Text(state.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor(state))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(stateColor(state).opacity(0.12)))
    }
}

struct RunRow: View {
    let run: WBRun
    let trailing: String
    var showsStatePill = false

    var body: some View {
        HStack(spacing: 8) {
            if !showsStatePill {
                Circle()
                    .fill(stateColor(run.state))
                    .frame(width: 7, height: 7)
            }
            Text(run.title)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if showsStatePill {
                StatePill(state: run.state)
            }
            Text(trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .help("\(run.title) — \(run.state)\(run.user?.username.map { " · \($0)" } ?? "")")
    }
}

struct WidgetView: View {
    @ObservedObject var model: WandbModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.updatedAt != nil {
                statusRow
            }
            projectRow
            Divider()
            content
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        // Same width as the Hacker News widget.
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
            Button("Open in W&B") {
                if let entity = model.entity, let project = model.selectedProject,
                   let url = URL(string: "https://wandb.ai/\(entity)/\(project)") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Open Log") { NSWorkspace.shared.open(WidgetLog.url) }
            Divider()
            WidgetChromeMenu()
            Divider()
            Button("Quit W&B Widget") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("W")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(wandbGold))
            SectionHeader(text: "Weights & Biases")
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

    private var statusRow: some View {
        let isRunning = !model.runningRuns.isEmpty
        let tint: Color = isRunning ? runningGreen : .secondary
        let label = isRunning
            ? "\(model.runningRuns.count) running"
            : "Idle"
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var projectRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.projects, id: \.self) { name in
                    Button {
                        model.select(project: name)
                    } label: {
                        if name == model.selectedProject {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedProject ?? "Select project")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(model.selectedProject == nil ? Color.secondary : wandbGold)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.projects.isEmpty)
            Spacer()
            if let entity = model.entity {
                Text(entity)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.runningRuns.isEmpty {
            runningSection
        } else if !model.latestRuns.isEmpty {
            latestSection
        } else if model.selectedProject != nil, model.updatedAt != nil {
            Text("No runs yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if model.errorMessage == nil {
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Active runs")
            ForEach(model.runningRuns) { run in
                RunRow(run: run, trailing: elapsedText(since: run.createdAt))
            }
        }
    }

    private var latestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Latest runs")
            ForEach(model.latestRuns) { run in
                RunRow(run: run, trailing: relativeText(run.createdAt), showsStatePill: true)
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
    private let model = WandbModel()
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

        if !window.setFrameUsingName("WandbWidget") {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                // Default just below where the Claude usage widget sits.
                window.setFrameTopLeftPoint(NSPoint(x: frame.minX + WidgetChrome.margin,
                                                    y: frame.maxY - 160))
            }
        }
        window.setFrameAutosaveName("WandbWidget")
        window.orderFrontRegardless()

        // Resize the window when the number of run rows changes.
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
