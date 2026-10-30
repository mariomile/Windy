import AppKit
import ApplicationServices

/// A standard window of a regular app, as seen through Accessibility.
final class TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let bundleID: String?
    let appName: String
    var minimized = false

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, app: NSRunningApplication) {
        self.id = id
        self.pid = pid
        self.element = element
        bundleID = app.bundleIdentifier
        appName = app.localizedName ?? "App"
    }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var icon: NSImage? { app?.icon }
    var title: String { element.string(kAXTitleAttribute) ?? "" }

    func focus() {
        element.set(kAXMinimizedAttribute, false as CFBoolean)
        element.set(kAXMainAttribute, true as CFBoolean)
        element.perform(kAXRaiseAction)
        // Cooperative activation can refuse a background app's activate(); asking the target
        // app through Accessibility to come forward is honored.
        AXUIElementCreateApplication(pid).set(kAXFrontmostAttribute, true as CFBoolean)
        app?.activate()
    }
}

/// Watches every regular app for windows opening, closing, moving and taking focus.
@MainActor
final class WindowTracker {
    private(set) var windows: [CGWindowID: TrackedWindow] = [:]
    /// Window IDs in the order they were first seen.
    private(set) var order: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var hiddenApps: Set<pid_t> = []
    private var started = false

    var onChange: (() -> Void)?
    var onGeometry: ((CGWindowID) -> Void)?
    var onFocus: (() -> Void)?
    var onSpaceChange: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.watch(app, attempt: 0) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.forget(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                // Some apps only become regular after launch: start watching them now.
                if let app { self?.watch(app, attempt: 0); self?.scan(app.processIdentifier) }
                self?.onFocus?()
            }
        }
        for (name, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    if hidden { self?.hiddenApps.insert(app.processIdentifier) } else { self?.hiddenApps.remove(app.processIdentifier) }
                    self?.onChange?()
                }
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSpaceChange?() }
        }
        for app in NSWorkspace.shared.runningApplications { watch(app, attempt: 0) }
    }

    // MARK: Queries

    /// Windows that should take part in tiling right now: visible on the current Space,
    /// not minimized, not hidden, not full screen. In first-seen order.
    func visibleWindows() -> [TrackedWindow] {
        let onScreen = Self.onScreenIDs()
        return order.compactMap { windows[$0] }.filter {
            !$0.minimized && !hiddenApps.contains($0.pid) && onScreen.contains($0.id) && !$0.element.bool("AXFullScreen")
        }
    }

    /// Windows a switcher should list: everything visible plus minimized ones.
    func switchableWindows() -> [TrackedWindow] {
        let onScreen = Self.onScreenIDs()
        return order.compactMap { windows[$0] }.filter { $0.minimized || onScreen.contains($0.id) }
    }

    static func onScreenIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        return el.element(kAXFocusedWindowAttribute)?.windowID
    }

    // MARK: Watching apps

    private func watch(_ app: NSRunningApplication, attempt: Int) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil, !app.isTerminated else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)

        // A freshly launched app may not answer Accessibility yet. Try again shortly.
        guard result == .success else {
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watch(app, attempt: attempt + 1) }
            }
            return
        }
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        if app.isHidden { hiddenApps.insert(pid) }
        scan(pid)
    }

    private func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        hiddenApps.remove(pid)
        let gone = windows.values.filter { $0.pid == pid }.map(\.id)
        guard !gone.isEmpty else { return }
        for id in gone { windows[id] = nil }
        order.removeAll { gone.contains($0) }
        onChange?()
    }

    func scanAll() {
        for pid in observers.keys { scan(pid, notify: false) }
        onChange?()
    }

    /// Re-reads one app's windows, adding new standard windows and dropping closed ones.
    func scan(_ pid: pid_t, notify: Bool = true) {
        guard let observer = observers[pid], let app = NSRunningApplication(processIdentifier: pid) else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let elements = appElement.windows
        var seen = Set<CGWindowID>()
        var changed = false

        for element in elements {
            guard let id = element.windowID else { continue }
            seen.insert(id)
            if let known = windows[id] {
                let minimized = element.bool(kAXMinimizedAttribute)
                if known.minimized != minimized { known.minimized = minimized; changed = true }
                continue
            }
            guard Self.isStandard(element) else { continue }
            let window = TrackedWindow(id: id, pid: pid, element: element, app: app)
            window.minimized = element.bool(kAXMinimizedAttribute)
            windows[id] = window
            order.append(id)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
            changed = true
        }

        // Windows on other Spaces can drop out of the list; only forget ones that no longer answer.
        for window in windows.values where window.pid == pid && !seen.contains(window.id) && window.element.role == nil {
            remove(window.id)
            changed = true
        }
        if changed && notify { onChange?() }
    }

    static func isStandard(_ element: AXUIElement) -> Bool {
        guard element.role == kAXWindowRole as String,
              element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              element.isSizeSettable,
              let frame = element.frame, frame.width > 60, frame.height > 60 else { return false }
        return true
    }

    private func remove(_ id: CGWindowID) {
        windows[id] = nil
        order.removeAll { $0 == id }
    }

    private func window(for element: AXUIElement) -> TrackedWindow? {
        if let id = element.windowID, let w = windows[id] { return w }
        return windows.values.first { CFEqual($0.element, element) }
    }

    fileprivate func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            let pid = element.pid
            scan(pid)
            // Some apps finish setting up a window (subrole, size) a moment after creating it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan(pid) }
        case kAXUIElementDestroyedNotification:
            if let w = window(for: element) {
                remove(w.id)
                onChange?()
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            if let w = window(for: element) {
                w.minimized = notification == kAXWindowMiniaturizedNotification
                onChange?()
            }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let w = window(for: element) { onGeometry?(w.id) }
        case kAXFocusedWindowChangedNotification:
            scan(element.pid)
            onFocus?()
        default:
            break
        }
    }
}

extension AXUIElement {
    var role: String? { string(kAXRoleAttribute) }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { tracker.handle(name, element) }
}
