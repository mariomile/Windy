import AppKit
import Carbon.HIToolbox
import SwiftUI
import WindyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Prefs.shared
    private let tracker = WindowTracker()
    private lazy var tiler = Tiler(tracker: tracker)
    private lazy var overlays = Overlays(tiler: tiler)
    private let hotKeys = HotKeys()
    private lazy var switcher = Switcher(tiler: tiler, hotKeys: hotKeys)
    private let model = AppModel()
    private lazy var workspaces = Workspaces(tiler: tiler)
    private lazy var commands = Commands(tiler: tiler, workspaces: workspaces)
    private lazy var server = CommandServer { [weak self] request, reply in
        MainActor.assumeIsolated {
            guard let self else { return reply(["ok": false, "error": "Windy is quitting."]) }
            self.commands.handle(request, reply: reply)
        }
    }

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var tourWindow: NSWindow?
    private var monitors: [Any] = []
    private var shortcutIDs: [UInt32] = []
    private var stageTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = prefs.appearance.nsAppearance
        model.tiler = tiler
        model.workspaces = workspaces
        model.showSettings = { [weak self] in self?.showSettings() }
        model.showTour = { [weak self] in self?.showTour() }

        tracker.onChange = { [weak self] in self?.tiler.scheduleReconcile() }
        tracker.onGeometry = { [weak self] id in self?.tiler.geometryChanged(id) }
        tracker.onFocus = { [weak self] in self?.tiler.focusChanged() }
        tracker.onSpaceChange = { [weak self] in self?.tiler.spaceChanged() }
        tiler.onStateChange = { [weak self] in self?.stateChanged() }

        // One Windy at a time: a second copy would fight the first over every window.
        guard server.start() else {
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
        registerShortcuts()
        setUpMonitors()
        watchSystem()

        if Accessibility.isTrusted { start() } else { waitForAccess() }
        if !prefs.setupDone || !Accessibility.isTrusted { showTour() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func start() {
        tracker.start()
        tiler.focusChanged()
        tiler.reconcile()
    }

    private func waitForAccess() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard Accessibility.isTrusted else { return }
                timer.invalidate()
                self?.start()
            }
        }
    }

    private func stateChanged() {
        overlays.update()
        model.refresh()
        statusItem.button?.image = WindyIcon.menuBar(active: tiler.isActive)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = WindyIcon.menuBar(active: false)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Windows

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let view = SettingsView(
                onLayoutChange: { [weak self] in self?.tiler.reconcile(); self?.tiler.applyAll() },
                onShortcutsChange: { [weak self] in self?.registerShortcuts() },
                showTour: { [weak self] in self?.showTour() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Windy Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showTour() {
        popover.performClose(nil)
        if tourWindow == nil {
            let view = OnboardingView { [weak self] in
                guard let self else { return }
                prefs.setupDone = true
                tourWindow?.close()
                tiler.reconcile()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Windy"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            tourWindow = window
        }
        tourWindow?.center()
        NSApp.activate()
        tourWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Shortcuts

    private func registerShortcuts() {
        hotKeys.unregister(shortcutIDs)
        let mods = Keys.modifiers(prefs.prefix)
        let shift = prefs.prefix == .controlShift ? 0 : Int(shiftKey)
        let t = tiler
        let actions: [String: () -> Void] = [
            "focus": { t.toggleFocusMode() },
            "noPeek": { t.noPeek.toggle() },
            "clean": { t.toggleCleanSpace() },
            "left": { t.swap(.left) },
            "right": { t.swap(.right) },
            "up": { t.swap(.up) },
            "down": { t.swap(.down) },
            "primary": { t.makePrimary() },
            "grow": { t.resize(by: 0.05) },
            "shrink": { t.resize(by: -0.05) },
            "reset": { t.resetSizes() },
            "next": { t.focusNeighbor(1) },
            "prev": { t.focusNeighbor(-1) },
            "stackNext": { t.cycleStack(1) },
            "stackPrev": { t.cycleStack(-1) },
            "float": { t.toggleFloat() },
        ]
        var ids: [UInt32] = []
        for s in Shortcuts.all {
            guard let action = actions[s.id] else { continue }
            // ⌃⇧ already has shift, so "previous in stack" isn't available with that prefix.
            if s.extraShift && shift == 0 { continue }
            ids.append(hotKeys.register(s.key, mods | (s.extraShift ? shift : 0), action))
        }
        let countMods = mods | Keys.countModifier(prefs.prefix).mask
        for (n, key) in Shortcuts.countKeys.enumerated() {
            ids.append(hotKeys.register(key, countMods) { t.setLayout(count: n + 1) })
        }
        ids.append(hotKeys.register(kVK_Tab, Int(optionKey)) { [weak self] in self?.switcher.step(1) })
        ids.append(hotKeys.register(kVK_Tab, Int(optionKey | shiftKey)) { [weak self] in self?.switcher.step(-1) })
        shortcutIDs = ids.filter { $0 != 0 }
    }

    // MARK: Mouse and system events

    private func setUpMonitors() {
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.tiler.mouseUp(modifiers: event.modifierFlags)
                self?.overlays.update()
            }
        }) { monitors.append(up) }
        if let move = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.tiler.hover(at: flippedPoint(NSEvent.mouseLocation)) }
        }) { monitors.append(move) }
    }

    private func watchSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tiler.endCleanSpace()
                self?.tiler.reconcile()
                self?.tiler.applyAll()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tiler.endCleanSpace() }
            }
        }
        // Stage Manager arranges windows its own way, so Windy steps aside while it's on.
        stageTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let on = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
                self?.tiler.stageManagerOn = on
            }
        }
        prefs.onChange = { [weak self] in self?.stateChanged() }
    }
}
