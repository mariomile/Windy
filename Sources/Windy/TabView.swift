import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import WindyCore

/// ⌥⇥ window switcher: every window, laid out screen by screen as it sits on the desktop.
@MainActor @Observable
final class SwitcherModel {
    struct Item: Identifiable {
        let id: CGWindowID
        let appName: String
        let title: String
        let icon: NSImage?
        let frame: CGRect
        let minimized: Bool
    }

    struct Screen: Identifiable {
        let id: String
        let frame: CGRect
        var items: [Item]
        var minimized: [Item]
    }

    var screens: [Screen] = []
    var order: [CGWindowID] = []
    var selected: CGWindowID?
    @ObservationIgnored var onPick: ((CGWindowID) -> Void)?
}

@MainActor
final class Switcher {
    private let tiler: Tiler
    private let hotKeys: HotKeys
    private let model = SwitcherModel()
    private var panel: NSPanel?
    private var temporaryKeys: [UInt32] = []
    private var flagMonitors: [Any] = []

    init(tiler: Tiler, hotKeys: HotKeys) {
        self.tiler = tiler
        self.hotKeys = hotKeys
        model.onPick = { [weak self] id in
            self?.model.selected = id
            self?.commit()
        }
    }

    var isOpen: Bool { panel != nil }

    /// ⌥⇥ opens it with the previous window picked; pressing again moves along.
    func step(_ delta: Int) {
        if isOpen {
            move(delta)
        } else {
            open(initialStep: delta)
        }
    }

    private func open(initialStep: Int) {
        let windows = tiler.tracker.switchableWindows()
        guard !windows.isEmpty else { return }
        // Most recently used first, then the rest in arrival order.
        let rank = Dictionary(uniqueKeysWithValues: tiler.mru.enumerated().map { ($1, $0) })
        let sorted = windows.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
        model.order = sorted.map(\.id)

        var screens = NSScreen.screens.map {
            SwitcherModel.Screen(id: $0.uuid, frame: $0.axFrame, items: [], minimized: [])
        }
        for w in sorted {
            let frame = w.element.frame ?? .zero
            let item = SwitcherModel.Item(id: w.id, appName: w.appName, title: w.title, icon: w.icon,
                                          frame: frame, minimized: w.minimized)
            let uuid = NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY))?.uuid
            guard let s = screens.firstIndex(where: { $0.id == uuid }) ?? screens.indices.first else { continue }
            if w.minimized { screens[s].minimized.append(item) } else { screens[s].items.append(item) }
        }
        model.screens = screens.filter { !$0.items.isEmpty || !$0.minimized.isEmpty }
        model.selected = model.order.count > 1 && initialStep > 0 ? model.order[1]
            : initialStep < 0 ? model.order.last : model.order.first

        // A quick ⌥⇥ that's already released switches straight back.
        guard NSEvent.modifierFlags.contains(.option) else {
            commit()
            return
        }
        show()
    }

    private func show() {
        let host = NSHostingView(rootView: SwitcherView(model: model))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        let screen = NSScreen.underPointer ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let option = optionKey
        temporaryKeys = [
            hotKeys.register(kVK_Escape, 0) { [weak self] in self?.close() },
            hotKeys.register(kVK_Escape, option) { [weak self] in self?.close() },
            hotKeys.register(kVK_Return, option) { [weak self] in self?.commit() },
            hotKeys.register(kVK_Return, 0) { [weak self] in self?.commit() },
            hotKeys.register(kVK_LeftArrow, option) { [weak self] in self?.moveSpatially(.left) },
            hotKeys.register(kVK_RightArrow, option) { [weak self] in self?.moveSpatially(.right) },
            hotKeys.register(kVK_UpArrow, option) { [weak self] in self?.moveSpatially(.up) },
            hotKeys.register(kVK_DownArrow, option) { [weak self] in self?.moveSpatially(.down) },
        ]
        // Letting go of ⌥ switches to the picked window.
        let handler: (NSEvent) -> Void = { [weak self] event in
            if !event.modifierFlags.contains(.option) { self?.commit() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { flagMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) {
            flagMonitors.append(local)
        }
    }

    private func move(_ delta: Int) {
        guard !model.order.isEmpty else { return }
        let i = model.selected.flatMap { model.order.firstIndex(of: $0) } ?? 0
        model.selected = model.order[(i + delta + model.order.count) % model.order.count]
    }

    private func moveSpatially(_ direction: Direction) {
        let items = model.screens.flatMap(\.items)
        guard let current = items.first(where: { $0.id == model.selected }) else { return }
        let rects = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.offset, $0.element.frame) })
        if let i = Layout.neighbor(of: current.frame, in: rects, direction: direction) { model.selected = items[i].id }
    }

    private func commit() {
        let picked = model.selected
        close()
        if let picked { tiler.focus(picked) }
    }

    func close() {
        hotKeys.unregister(temporaryKeys)
        temporaryKeys = []
        for monitor in flagMonitors { NSEvent.removeMonitor(monitor) }
        flagMonitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}

struct SwitcherView: View {
    let model: SwitcherModel
    private let height: CGFloat = 240

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(model.screens) { screen in
                VStack(alignment: .leading, spacing: 10) {
                    screenMap(screen)
                    if !screen.minimized.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(screen.minimized) { item in
                                chip(item).frame(width: 150, height: 34)
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func screenMap(_ screen: SwitcherModel.Screen) -> some View {
        let scale = min(height / screen.frame.height, 520 / screen.frame.width)
        let size = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.18))
            ForEach(screen.items) { item in
                let r = item.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                chip(item)
                    .frame(width: max(40, r.width * scale - 4), height: max(30, r.height * scale - 4))
                    .offset(x: r.minX * scale + 2, y: r.minY * scale + 2)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func chip(_ item: SwitcherModel.Item) -> some View {
        let selected = item.id == model.selected
        return VStack(spacing: 4) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            }
            Text(item.appName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            if !item.title.isEmpty {
                Text(item.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        .contentShape(Rectangle())
        .onTapGesture { model.onPick?(item.id) }
    }
}
