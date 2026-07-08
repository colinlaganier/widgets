import AppKit
import SwiftUI

/// Shared window behaviour for every desktop widget, compiled into each app
/// alongside its main.swift (see build.sh).
///
/// Provides:
///  - Snap-to-place: releasing a drag near the screen edge or another widget
///    snaps the window into alignment (left/right margin, stacked above or
///    below its neighbours) with a short animation and a haptic tick.
///  - "Arrange in Left Column": one widget broadcasts over
///    DistributedNotificationCenter and every running widget process moves its
///    own window into a single left-edge column, top to bottom.
///  - Desktop pinning: widgets show on all Spaces by default; the shared
///    context-menu toggle pins one to the desktop it is currently on. To move
///    a pinned widget to another desktop: re-enable "Show on All Desktops",
///    switch desktops, then disable it again.
final class WidgetChrome: NSObject {
    static let shared = WidgetChrome()

    /// Shared layout metrics so every widget lines up on the same column.
    static let margin: CGFloat = 24
    static let gap: CGFloat = 16
    static let snapDistance: CGFloat = 32

    private static let arrangeNote = Notification.Name("com.colin.widgets.arrange")
    private static let dragBeganNote = Notification.Name("com.colin.widgets.dragBegan")
    private static let dragMovedNote = Notification.Name("com.colin.widgets.dragMoved")
    private static let dragEndedNote = Notification.Name("com.colin.widgets.dragEnded")
    private static let gatherNote = Notification.Name("com.colin.widgets.gather")
    private static let reelectNote = Notification.Name("com.colin.widgets.reelect")
    private static let allDesktopsNote = Notification.Name("com.colin.widgets.setAllDesktops")
    private static let allDesktopsKey = "WidgetChrome.showOnAllDesktops"

    private var window: NSWindow?
    private var dragPoll: Timer?

    // Group-drag state (see "Group drag handle" below).
    private var handleWindow: NSWindow?
    private var handleDragStartFrame: NSRect?
    private var groupDragStartOrigin: NSPoint?
    private var isGroupDragging = false
    private var lastDragBroadcast: TimeInterval = 0
    private var electionTimer: Timer?

    // MARK: - Adoption

    /// Call once from applicationDidFinishLaunching after creating the window.
    /// Replaces the per-widget level/collectionBehavior setup.
    func adopt(_ window: NSWindow) {
        self.window = window
        // One step above Finder's desktop icons (which would otherwise cover
        // the widget and swallow clicks), still below normal app windows.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        applyPlacement()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification, object: window)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(arrangeSelf), name: Self.arrangeNote, object: nil)
        dnc.addObserver(self, selector: #selector(groupDragBegan), name: Self.dragBeganNote, object: nil)
        dnc.addObserver(self, selector: #selector(groupDragMoved(_:)), name: Self.dragMovedNote, object: nil)
        dnc.addObserver(self, selector: #selector(groupDragEnded(_:)), name: Self.dragEndedNote, object: nil)
        dnc.addObserver(self, selector: #selector(gatherToActiveSpace), name: Self.gatherNote, object: nil)
        dnc.addObserver(self, selector: #selector(reelectSoon), name: Self.reelectNote, object: nil)
        dnc.addObserver(self, selector: #selector(setAllDesktops(_:)), name: Self.allDesktopsNote, object: nil)

        // The bottom-most widget hosts the group drag handle; keep the
        // election fresh even when no move notifications reach this process
        // (another widget quitting or launching, for example).
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, !self.isGroupDragging else { return }
            self.updateHandleOwnership()
        }
        electionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.updateHandleOwnership()
        }
    }

    // MARK: - Desktop (Space) pinning

    var showOnAllDesktops: Bool {
        get { UserDefaults.standard.object(forKey: Self.allDesktopsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.allDesktopsKey)
            applyPlacement(pullToActiveSpace: !newValue)
        }
    }

    private func applyPlacement(pullToActiveSpace: Bool = false) {
        guard let window else { return }
        if showOnAllDesktops {
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else if pullToActiveSpace {
            // Grab the window onto the desktop the user is looking at, then
            // drop the flag so it stays put there.
            window.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]
            window.orderFrontRegardless()
            DispatchQueue.main.async {
                window.collectionBehavior = [.stationary, .ignoresCycle]
            }
        } else {
            window.collectionBehavior = [.stationary, .ignoresCycle]
        }
    }

    // MARK: - Snap into place after a drag

    @objc private func windowDidMove(_ note: Notification) {
        // Programmatic setFrame calls also post didMove; only react while the
        // user is actually holding a drag. Group drags via the handle keep
        // exact relative positions, so individual snapping stays out of them.
        guard !isGroupDragging, NSEvent.pressedMouseButtons & 1 == 1, dragPoll == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self?.dragPoll = nil
            self?.snapIntoPlace()
            // The bottom-most widget may have changed; everyone re-elects.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.reelectNote, object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        dragPoll = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func snapIntoPlace() {
        guard let window, let screen = screenContaining(window.frame) else { return }
        let visible = screen.visibleFrame
        var frame = window.frame

        var xCandidates = [visible.minX + Self.margin,
                           visible.maxX - Self.margin - frame.width]
        var topCandidates = [visible.maxY - Self.margin]
        for peer in peerWindows() {
            xCandidates.append(peer.frame.minX)                          // align left edges
            topCandidates.append(peer.frame.minY - Self.gap)             // slot below the peer
            topCandidates.append(peer.frame.maxY + Self.gap + frame.height) // slot above it
        }

        if let x = nearest(to: frame.minX, among: xCandidates) { frame.origin.x = x }
        if let top = nearest(to: frame.maxY, among: topCandidates) {
            frame.origin.y = top - frame.height
        }

        guard frame != window.frame else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        window.setFrame(frame, display: true, animate: true)
        saveFrameSoon()
    }

    private func nearest(to value: CGFloat, among candidates: [CGFloat]) -> CGFloat? {
        guard let best = candidates.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(best - value) <= Self.snapDistance else { return nil }
        return best
    }

    // MARK: - Arrange every widget into the left column

    /// Broadcast to all widget processes; each one moves only its own window.
    static func arrangeAll() {
        DistributedNotificationCenter.default().postNotificationName(
            arrangeNote, object: nil, userInfo: nil, deliverImmediately: true)
    }

    @objc private func arrangeSelf() {
        // Widgets pinned to another desktop keep their own layout.
        guard let window, window.isOnActiveSpace,
              let screen = screenContaining(window.frame) else { return }
        let visible = screen.visibleFrame

        // Every process sees the same pre-move snapshot (the notification is
        // delivered before anyone starts animating 100 ms later), so they all
        // compute the same top-to-bottom order.
        let column = allWidgetWindows()
            .filter { screenContaining($0.frame) == screen }
            .sorted {
                $0.frame.maxY != $1.frame.maxY
                    ? $0.frame.maxY > $1.frame.maxY
                    : $0.number < $1.number
            }

        // The pill re-anchors under whichever widget ends up lowest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateHandleOwnership()
        }

        var top = visible.maxY - Self.margin
        for item in column {
            if item.number == window.windowNumber {
                let target = NSRect(x: visible.minX + Self.margin,
                                    y: top - item.frame.height,
                                    width: item.frame.width, height: item.frame.height)
                guard target != window.frame else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    window.setFrame(target, display: true, animate: true)
                    self?.saveFrameSoon()
                }
                return
            }
            top -= item.frame.height + Self.gap
        }
    }

    // MARK: - Finding the other widgets

    private struct WidgetWindowInfo: Equatable {
        let number: Int
        let frame: NSRect
    }

    private func peerWindows() -> [WidgetWindowInfo] {
        allWidgetWindows().filter { $0.number != window?.windowNumber }
    }

    /// All on-screen widget windows (this one included), identified by sharing
    /// our unusual window level. Bounds only — no screen-recording permission
    /// is needed for window frames.
    private func allWidgetWindows() -> [WidgetWindowInfo] {
        guard let window,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return [] }
        // CGWindow bounds are top-left origin; AppKit is bottom-left.
        let flipHeight = primary.frame.maxY
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == window.level.rawValue,
                  // The window server parks menu-bar/wallpaper backdrops at
                  // this level too; only real widget processes count.
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  owner != "Window Server",
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let frame = NSRect(x: bounds.minX, y: flipHeight - bounds.maxY,
                               width: bounds.width, height: bounds.height)
            return WidgetWindowInfo(number: number, frame: frame)
        }
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
            ?? NSScreen.main
    }

    // MARK: - Group drag handle

    /// The bottom-most widget on each screen shows a small rounded pill
    /// centered below itself. Dragging the pill moves every widget together:
    /// the hosting process moves the pill and broadcasts the cumulative
    /// offset, and each widget process (this one included — distributed
    /// notifications are delivered locally too) applies it to its own window.
    /// Right-clicking the pill offers group actions.
    private func updateHandleOwnership() {
        guard let window, !isGroupDragging,
              let screen = screenContaining(window.frame) else { return }
        let group = allWidgetWindows().filter { screenContaining($0.frame) == screen }
        let host = group.min {
            $0.frame.minY != $1.frame.minY
                ? $0.frame.minY < $1.frame.minY
                : $0.number < $1.number
        }
        if host?.number == window.windowNumber {
            showHandle(below: window.frame)
        } else {
            handleWindow?.orderOut(nil)
            handleWindow = nil
        }
    }

    private func showHandle(below widgetFrame: NSRect) {
        let size = NSSize(width: 120, height: 22)
        let frame = NSRect(x: widgetFrame.midX - size.width / 2,
                           y: widgetFrame.minY - 6 - size.height,
                           width: size.width, height: size.height)
        if let handleWindow {
            handleWindow.setFrame(frame, display: true)
            handleWindow.orderFrontRegardless()
            return
        }

        let handle = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        handle.isOpaque = false
        handle.backgroundColor = .clear
        handle.hasShadow = false
        handle.isMovable = false
        // One above the widgets themselves, so the peer scan (which matches
        // the widget level exactly) never mistakes the pill for a widget.
        handle.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        // Always on every desktop: the pill stays reachable even when the
        // widgets are pinned to another one, so "Gather All Widgets Here"
        // can bring them over.
        handle.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = WidgetHandleView(frame: NSRect(origin: .zero, size: size))
        view.onDragBegan = { [weak self] in
            guard let self else { return }
            self.isGroupDragging = true
            self.handleDragStartFrame = self.handleWindow?.frame
            DistributedNotificationCenter.default().postNotificationName(
                Self.dragBeganNote, object: nil, userInfo: nil, deliverImmediately: true)
        }
        view.onDragMoved = { [weak self] total in
            guard let self, let handleWindow = self.handleWindow,
                  let start = self.handleDragStartFrame else { return }
            handleWindow.setFrame(start.offsetBy(dx: total.x, dy: total.y), display: true)
            // The pill tracks the mouse at full rate; followers get ~30 Hz.
            // Offsets are cumulative, so dropped updates never accumulate
            // error, and drag-end always sends the exact final offset.
            let now = CACurrentMediaTime()
            guard now - self.lastDragBroadcast > 1.0 / 30.0 else { return }
            self.lastDragBroadcast = now
            DistributedNotificationCenter.default().postNotificationName(
                Self.dragMovedNote, object: nil,
                userInfo: ["dx": Double(total.x), "dy": Double(total.y)],
                deliverImmediately: true)
        }
        view.onDragEnded = { total in
            DistributedNotificationCenter.default().postNotificationName(
                Self.dragEndedNote, object: nil,
                userInfo: ["dx": Double(total.x), "dy": Double(total.y)],
                deliverImmediately: true)
        }
        view.menuProvider = { [weak self] in self?.handleMenu() }
        handle.contentView = view
        handle.orderFrontRegardless()
        handleWindow = handle
    }

    private func handleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Arrange Widgets in Left Column",
                     action: #selector(menuArrange), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Gather All Widgets Here",
                     action: #selector(menuGather), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let pin = NSMenuItem(title: "Show Widgets on All Desktops",
                             action: #selector(menuToggleAllDesktops), keyEquivalent: "")
        pin.target = self
        pin.state = showOnAllDesktops ? .on : .off
        menu.addItem(pin)
        return menu
    }

    @objc private func menuArrange() { Self.arrangeAll() }

    @objc private func menuGather() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.gatherNote, object: nil, userInfo: nil, deliverImmediately: true)
    }

    @objc private func menuToggleAllDesktops() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.allDesktopsNote, object: nil,
            userInfo: ["value": !showOnAllDesktops], deliverImmediately: true)
    }

    // MARK: - Group notifications (every widget process runs these)

    @objc private func groupDragBegan() {
        isGroupDragging = true
        groupDragStartOrigin = window?.frame.origin
    }

    @objc private func groupDragMoved(_ note: Notification) {
        guard let window, let start = groupDragStartOrigin,
              let dx = note.userInfo?["dx"] as? Double,
              let dy = note.userInfo?["dy"] as? Double else { return }
        window.setFrameOrigin(NSPoint(x: start.x + dx, y: start.y + dy))
    }

    @objc private func groupDragEnded(_ note: Notification) {
        groupDragMoved(note)
        isGroupDragging = false
        groupDragStartOrigin = nil
        saveFrameSoon()
        // The column may have landed on another screen; re-anchor the pill.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateHandleOwnership()
        }
    }

    /// Pull this widget onto the desktop the user is looking at, keeping its
    /// pin mode. No-op for widgets already visible here (including any set to
    /// show on all desktops).
    @objc private func gatherToActiveSpace() {
        guard let window, !window.isOnActiveSpace else { return }
        window.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            self.applyPlacement()
            self.updateHandleOwnership()
        }
    }

    @objc private func reelectSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateHandleOwnership()
        }
    }

    @objc private func setAllDesktops(_ note: Notification) {
        guard let value = note.userInfo?["value"] as? Bool else { return }
        showOnAllDesktops = value
    }

    /// setFrame(animate:) finishes asynchronously; save once it has settled so
    /// the autosaved frame matches where the window ended up.
    private func saveFrameSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let window = self?.window, !window.frameAutosaveName.isEmpty else { return }
            window.saveFrame(usingName: window.frameAutosaveName)
        }
    }
}

/// The rounded pill drawn inside the handle window. Tracks drags in screen
/// coordinates and reports cumulative offsets; right-click pops the group menu.
final class WidgetHandleView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var dragStart: NSPoint?
    private var trackingArea: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragging = true
        NSCursor.closedHand.set()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let now = NSEvent.mouseLocation
        onDragMoved?(NSPoint(x: now.x - dragStart.x, y: now.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let dragStart else { return }
        dragging = false
        (hovering ? NSCursor.openHand : NSCursor.arrow).set()
        let now = NSEvent.mouseLocation
        onDragEnded?(NSPoint(x: now.x - dragStart.x, y: now.y - dragStart.y))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pillSize = NSSize(width: 72, height: 7)
        let pill = NSRect(x: (bounds.width - pillSize.width) / 2,
                          y: (bounds.height - pillSize.height) / 2,
                          width: pillSize.width, height: pillSize.height)
        let alpha: CGFloat = dragging ? 0.6 : hovering ? 0.5 : 0.3
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: pill,
                     xRadius: pillSize.height / 2,
                     yRadius: pillSize.height / 2).fill()
    }
}

/// Shared placement section for each widget's context menu.
struct WidgetChromeMenu: View {
    var body: some View {
        Button("Arrange Widgets in Left Column") { WidgetChrome.arrangeAll() }
        Toggle("Show on All Desktops", isOn: Binding(
            get: { WidgetChrome.shared.showOnAllDesktops },
            set: { WidgetChrome.shared.showOnAllDesktops = $0 }
        ))
    }
}
