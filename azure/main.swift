import AppKit
import Combine
import SwiftUI

// MARK: - Data model

struct AzureVM: Codable, Identifiable, Hashable {
    let name: String
    let resourceGroup: String
    var powerState: String?
    /// Comma-separated in `az vm list -d` output.
    var publicIps: String?
    var fqdns: String?
    var adminUsername: String?
    var vmSize: String?

    /// "Standard_NC96ads_A100_v4" → "NC96ads A100 v4"
    var sizeText: String? {
        guard var size = vmSize, !size.isEmpty else { return nil }
        if size.hasPrefix("Standard_") { size.removeFirst("Standard_".count) }
        return size.replacingOccurrences(of: "_", with: " ")
    }

    var id: String { "\(resourceGroup)/\(name)" }

    /// "user@host" for Remote-SSH; nil while the VM has no reachable address.
    var sshTarget: String? {
        let host = [fqdns, publicIps]
            .compactMap { $0?.split(separator: ",").first.map(String.init) }
            .first { !$0.isEmpty }
        guard let host else { return nil }
        guard let adminUsername, !adminUsername.isEmpty else { return host }
        return "\(adminUsername)@\(host)"
    }

    /// "VM running" → "Running"
    var stateText: String {
        guard let powerState, !powerState.isEmpty else { return "Unknown" }
        let trimmed = powerState.hasPrefix("VM ") ? String(powerState.dropFirst(3)) : powerState
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    var isRunning: Bool { powerState == "VM running" }
    var isStopped: Bool { powerState == "VM deallocated" || powerState == "VM stopped" }
    /// Starting, stopping, deallocating — anything in flight.
    var isTransitioning: Bool { powerState != nil && !isRunning && !isStopped }
}

enum WidgetError: Error {
    case azNotFound
    case notLoggedIn
    case cli(String)

    var message: String {
        switch self {
        case .azNotFound: return "Azure CLI not found — brew install azure-cli"
        case .notLoggedIn: return "Not logged in — run: az login"
        case .cli(let detail): return detail
        }
    }
}

// MARK: - Logging

enum WidgetLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AzureWidget.log")
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

// MARK: - Azure CLI

enum AzureCLI {
    /// GUI apps don't inherit the shell PATH, so locate az directly.
    private static let path: String? = {
        let candidates = [
            "/opt/homebrew/bin/az",
            "/usr/local/bin/az",
            "\(NSHomeDirectory())/bin/az",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func run(_ arguments: [String]) throws -> Data {
        guard let path else { throw WidgetError.azNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // Never fall back to a browser prompt from a background process.
        env["AZURE_CORE_LOGIN_EXPERIENCE_V2"] = "off"
        process.environment = env

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errData, encoding: .utf8) ?? ""
            if stderrText.contains("az login") || stderrText.contains("AADSTS") {
                throw WidgetError.notLoggedIn
            }
            let firstError = stderrText
                .split(separator: "\n")
                .first { $0.contains("ERROR") } ?? "az exited with \(process.terminationStatus)"
            throw WidgetError.cli(String(firstError.prefix(120)))
        }
        return outData
    }
}

// MARK: - VS Code

enum VSCode {
    private static let cliPath: String? = {
        let candidates = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Opens a new VS Code window connected to `target` over Remote-SSH.
    static func openRemote(_ target: String) {
        if let cliPath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["--new-window", "--remote", "ssh-remote+\(target)"]
            if (try? process.run()) != nil { return }
        }
        // No CLI — fall back to the URL scheme ("@" and "+" stay literal).
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        if let url = URL(string: "vscode://vscode-remote/ssh-remote+\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Model

final class AzureModel: ObservableObject {
    @Published var vms: [AzureVM] = []
    @Published var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedVM") }
    }
    @Published var errorMessage: String?
    @Published var updatedAt: Date?
    @Published var isRefreshing = false
    /// Non-nil while a start/deallocate command is being issued.
    @Published var pendingAction: String?

    private var timer: Timer?

    /// VM state rarely changes on its own; poll the full list every 5 minutes
    /// but check the selected VM every 10 s while it is starting or stopping.
    private static let pollInterval: TimeInterval = 300
    private static let transitionPollInterval: TimeInterval = 10
    private static let retryInterval: TimeInterval = 120
    private var nextAttempt: Date = .distantPast

    var selectedVM: AzureVM? {
        vms.first { $0.id == selectedID }
    }

    func start() {
        WidgetLog.write("Widget started (poll interval \(Int(Self.pollInterval))s)")
        loadCache()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh(force: true)
        }
    }

    /// `force` (manual refresh) bypasses the schedule.
    func refresh(force: Bool = false) {
        guard force || Date() >= nextAttempt else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        nextAttempt = Date().addingTimeInterval(Self.pollInterval)

        // While the selected VM is transitioning, poll just that VM — much
        // faster than listing the whole subscription.
        if !force, let vm = selectedVM, vm.isTransitioning {
            refreshSelected(vm)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let data = try AzureCLI.run([
                    "vm", "list", "-d",
                    "--query", "[].{name:name, resourceGroup:resourceGroup, powerState:powerState,"
                        + " publicIps:publicIps, fqdns:fqdns, adminUsername:osProfile.adminUsername,"
                        + " vmSize:hardwareProfile.vmSize}",
                    "-o", "json",
                ])
                let fetched = try JSONDecoder().decode([AzureVM].self, from: data)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.vms = fetched
                    if self.selectedVM == nil {
                        self.selectedID = fetched.first?.id
                    }
                    if self.errorMessage != nil {
                        WidgetLog.write("Recovered — \(fetched.count) VMs fetched")
                    }
                    self.errorMessage = nil
                    self.updatedAt = Date()
                    self.scheduleNextPoll()
                    if let data = try? JSONEncoder().encode(fetched) {
                        UserDefaults.standard.set(data, forKey: "cachedVMs")
                        UserDefaults.standard.set(Date(), forKey: "cachedVMsDate")
                    }
                }
            } catch {
                self?.fail(error)
            }
        }
    }

    private func refreshSelected(_ vm: AzureVM) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let data = try AzureCLI.run([
                    "vm", "show", "-d",
                    "-g", vm.resourceGroup, "-n", vm.name,
                    "--query", "powerState", "-o", "tsv",
                ])
                let state = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.setState(state, for: vm.id)
                    self.errorMessage = nil
                    self.updatedAt = Date()
                    if self.selectedVM?.isTransitioning == false {
                        // Settled — do a full list refresh so the public IP
                        // (assigned on start, dropped on deallocate) is current.
                        self.nextAttempt = .distantPast
                    } else {
                        self.scheduleNextPoll()
                    }
                }
            } catch {
                self?.fail(error)
            }
        }
    }

    // MARK: Actions

    func startVM() { perform("start", label: "Starting", optimisticState: "VM starting") }
    func stopVM() { perform("deallocate", label: "Shutting down", optimisticState: "VM deallocating") }

    func connectVSCode() {
        guard let vm = selectedVM, let target = vm.sshTarget else { return }
        WidgetLog.write("Opening VS Code Remote-SSH to \(target)")
        VSCode.openRemote(target)
    }

    private func perform(_ command: String, label: String, optimisticState: String) {
        guard let vm = selectedVM, pendingAction == nil else { return }
        pendingAction = label
        WidgetLog.write("\(label) \(vm.id)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                _ = try AzureCLI.run([
                    "vm", command,
                    "-g", vm.resourceGroup, "-n", vm.name,
                    "--no-wait",
                ])
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingAction = nil
                    self.errorMessage = nil
                    // Show the in-flight state immediately; polling confirms it.
                    self.setState(optimisticState, for: vm.id)
                    self.nextAttempt = Date().addingTimeInterval(Self.transitionPollInterval)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingAction = nil
                    let message = (error as? WidgetError)?.message ?? error.localizedDescription
                    self.errorMessage = message
                    WidgetLog.write("\(label) \(vm.id) failed: \(message)")
                }
            }
        }
    }

    // MARK: Helpers

    private func setState(_ state: String, for id: String) {
        guard let index = vms.firstIndex(where: { $0.id == id }) else { return }
        vms[index].powerState = state
    }

    private func scheduleNextPoll() {
        let transitioning = selectedVM?.isTransitioning ?? false
        nextAttempt = Date().addingTimeInterval(
            transitioning ? Self.transitionPollInterval : Self.pollInterval)
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRefreshing = false
            // Keep showing the last known data; just note the failure.
            self.errorMessage = (error as? WidgetError)?.message ?? error.localizedDescription
            self.nextAttempt = Date().addingTimeInterval(Self.retryInterval)
            WidgetLog.write("Fetch failed: \(self.errorMessage ?? "unknown") — retry in \(Int(Self.retryInterval))s")
        }
    }

    /// Show the last successful response while the first fetch is pending.
    private func loadCache() {
        selectedID = UserDefaults.standard.string(forKey: "selectedVM")
        guard let data = UserDefaults.standard.data(forKey: "cachedVMs"),
              let cached = try? JSONDecoder().decode([AzureVM].self, from: data)
        else { return }
        vms = cached
        updatedAt = UserDefaults.standard.object(forKey: "cachedVMsDate") as? Date
    }
}

// MARK: - Views

private let azureBlue = Color(red: 0.0, green: 0.47, blue: 0.83) // #0078d4
private let stateGreen = Color(red: 0.10, green: 0.60, blue: 0.25)
private let stateGray = Color(red: 0.45, green: 0.48, blue: 0.52)

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

/// Round icon button in the style of the Hacker News widget's comments button.
struct CircleButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4)
                    : (hovering ? Color.primary : Color.secondary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering && !disabled ? 0.14 : 0.07)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct WidgetView: View {
    @ObservedObject var model: AzureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            vmRow
            if model.selectedVM != nil {
                statusRow
            }
            Divider()
            actionRow
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
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
            Button("Open Azure Portal") {
                NSWorkspace.shared.open(URL(string: "https://portal.azure.com/#browse/Microsoft.Compute%2FVirtualMachines")!)
            }
            Button("Open Log") { NSWorkspace.shared.open(WidgetLog.url) }
            Divider()
            WidgetChromeMenu()
            Divider()
            Button("Quit Azure Widget") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(azureBlue))
            SectionHeader(text: "Azure")
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
        let vm = model.selectedVM
        let transitioning = model.pendingAction != nil || (vm?.isTransitioning ?? false)
        let tint: Color = transitioning ? .orange : ((vm?.isRunning ?? false) ? stateGreen : stateGray)
        let label = model.pendingAction.map { "\($0)…" } ?? (vm?.stateText ?? "Unknown")
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                if transitioning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))

            sizeLabel
        }
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if let size = model.selectedVM?.sizeText {
            Text(size)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var vmRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.vms) { vm in
                    Button {
                        model.selectedID = vm.id
                    } label: {
                        if vm.id == model.selectedID {
                            Label(vm.name, systemImage: "checkmark")
                        } else {
                            Text(vm.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedVM?.name ?? (model.vms.isEmpty ? "No VMs" : "Select VM"))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(model.selectedVM == nil ? Color.secondary : azureBlue)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.vms.isEmpty)
            Spacer()
            if let vm = model.selectedVM {
                Text(vm.resourceGroup)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if let vm = model.selectedVM {
            let busy = model.pendingAction != nil || vm.isTransitioning
            HStack(spacing: 8) {
                CircleButton(
                    systemImage: "play.fill",
                    help: "Start \(vm.name)",
                    disabled: busy || vm.isRunning
                ) { model.startVM() }

                CircleButton(
                    systemImage: "power",
                    help: "Deallocate \(vm.name) (stops billing)",
                    disabled: busy || vm.isStopped
                ) { model.stopVM() }

                CircleButton(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    help: vm.sshTarget.map { "Open VS Code Remote-SSH to \($0)" }
                        ?? "No public address to connect to",
                    disabled: !vm.isRunning || vm.sshTarget == nil
                ) { model.connectVSCode() }

                Spacer()

                if let updatedAt = model.updatedAt {
                    Text("Updated \(relativeText(updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if model.errorMessage == nil {
            Text(model.updatedAt == nil ? "Loading…" : "No virtual machines found")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
    private let model = AzureModel()
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

        if !window.setFrameUsingName("AzureWidget") {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                // Default below where the GitHub widget sits.
                window.setFrameTopLeftPoint(NSPoint(x: frame.minX + WidgetChrome.margin,
                                                    y: frame.maxY - 1060))
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
        window.setFrameAutosaveName("AzureWidget")
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
