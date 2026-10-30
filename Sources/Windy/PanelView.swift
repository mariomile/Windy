import SwiftUI
import WindyCore

/// The menu bar panel: status, a preview of this screen, its layout, and every quick switch.
struct PanelView: View {
    @Bindable var model: AppModel
    @Bindable var prefs = Prefs.shared
    @State private var workspaceName = ""
    @State private var workspaceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.status == .noAccess {
                card("Windy needs Accessibility access to move and resize windows.", button: "Grant Access") {
                    Accessibility.prompt()
                    Accessibility.openSettings()
                }
            } else if model.status == .setup {
                card("Finish the short setup to start tiling.", button: "Continue") { model.showTour() }
            }

            preview
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Windows on this screen").font(.caption).foregroundStyle(.secondary)
                Picker("Layout", selection: Binding(
                    get: { model.layout.kind },
                    set: { model.tiler?.setLayout(kind: $0, screen: model.screenUUID) }
                )) {
                    ForEach(LayoutKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Count", selection: Binding(
                    get: { min(model.layout.count, model.maxCount) },
                    set: { model.tiler?.setLayout(count: $0, screen: model.screenUUID) }
                )) {
                    ForEach(1...model.maxCount, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                toggle("Focus mode", "Z", isOn: model.focusMode) { model.tiler?.toggleFocusMode() }
                toggle("No peek", "D", isOn: model.noPeek) { model.tiler?.noPeek.toggle() }
                if model.noPeek {
                    Slider(value: $prefs.noPeekDim, in: 0.1...0.9) { Text("Dim") }
                        .controlSize(.small)
                }
                toggle("Clean Space", "P", isOn: model.cleanSpace) { model.tiler?.toggleCleanSpace() }
                if let name = model.frontAppName, let bundle = model.frontBundleID {
                    Toggle(isOn: Binding(
                        get: { !prefs.isExcluded(bundle) },
                        set: { prefs.setExcluded(bundle, !$0); model.tiler?.reconcile() }
                    )) { Text("Tile \(name)") }
                    .toggleStyle(.switch).controlSize(.small)
                }
            }

            Divider()

            if let workspaces = model.workspaces {
                workspaceSection(workspaces)
                Divider()
            }

            HStack {
                Button("Settings…") { model.showSettings() }
                Spacer()
                Button("Quit Windy") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: WindyIcon.menuBar(active: true)).renderingMode(.template)
            VStack(alignment: .leading, spacing: 2) {
                Text("Windy").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: model.status.color)).frame(width: 7, height: 7)
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { prefs.tilingEnabled },
                set: { prefs.tilingEnabled = $0; model.tiler?.reconcile() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private func workspaceSection(_ workspaces: Workspaces) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspaces").font(.caption).foregroundStyle(.secondary)
            ForEach(workspaces.all, id: \.name) { ws in
                HStack {
                    Text(ws.name).lineLimit(1)
                    Spacer()
                    Button("Open") {
                        workspaceError = nil
                        do {
                            try workspaces.open(ws.name) { reply in
                                let missing = ((reply["result"] as? JSON)?["missing"] as? [String]) ?? []
                                workspaceError = missing.isEmpty ? nil : "Missing: " + missing.joined(separator: ", ")
                            }
                        } catch let error as CommandError {
                            workspaceError = error.message
                        } catch {}
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                TextField("Save this setup as…", text: $workspaceName)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(saveWorkspace)
                Button("Save", action: saveWorkspace)
                    .controlSize(.small)
                    .disabled(workspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let workspaceError {
                Text(workspaceError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func saveWorkspace() {
        let name = workspaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let workspaces = model.workspaces else { return }
        do {
            try workspaces.saveCurrent(name)
            workspaceName = ""
            workspaceError = nil
        } catch let error as CommandError {
            workspaceError = error.message
        } catch {}
    }

    private var preview: some View {
        let frame = model.screenFrame
        let width: CGFloat = 288
        let scale = frame.width > 0 ? width / frame.width : 0
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
            ForEach(model.preview) { tile in
                let r = tile.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(tile.zoomed || !model.focusMode ? 0.12 : 0.05))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tile.active ? Color(nsColor: prefs.highlightColor) : .clear, lineWidth: 2))
                        .overlay {
                            if let icon = tile.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                        }
                    if tile.stacked > 1 {
                        Text("\(tile.stacked)").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).background(Capsule().fill(.orange)).foregroundStyle(.white)
                            .padding(3)
                    }
                    if tile.zoomed {
                        Text("Focus").font(.system(size: 9, weight: .semibold)).padding(3)
                    }
                }
                .frame(width: max(8, r.width * scale), height: max(8, r.height * scale))
                .offset(x: r.minX * scale, y: r.minY * scale)
            }
            if model.customSizes {
                Button("Reset sizes") { model.tiler?.resetSizes(model.screenUUID) }
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
        }
        .frame(width: width, height: max(60, frame.height * scale))
    }

    private func toggle(_ title: String, _ key: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) { Text(title) }
                .toggleStyle(.switch).controlSize(.small)
            Spacer()
            Text(prefs.prefix.symbols + key).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func card(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout)
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
