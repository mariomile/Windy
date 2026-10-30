import Combine
import SwiftUI
import WindyCore

/// The welcome tour: what Windy does, Accessibility access, a few choices, then the first tidy.
struct OnboardingView: View {
    @Bindable var prefs = Prefs.shared
    var onFinish: () -> Void
    @State private var step = 0
    @State private var trusted = Accessibility.isTrusted
    @State private var waited = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: WindyIcon.app(size: 64))
            switch step {
            case 0: welcome
            case 1: access
            default: choices
            }
            Spacer(minLength: 0)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                switch step {
                case 0: Button("Get started") { step = 1 }.keyboardShortcut(.defaultAction)
                case 1: Button("Continue") { step = 2 }.keyboardShortcut(.defaultAction).disabled(!trusted)
                default: Button("Tidy My Workspace", action: onFinish).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 460, height: 420)
        .onReceive(timer) { _ in
            trusted = Accessibility.isTrusted
            if step == 1, !trusted { waited += 1 }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to Windy").font(.largeTitle.bold())
            Text("Open a window and Windy gives it a place. Close one and the rest fill the space. No dragging, no layouts to draw.")
                .foregroundStyle(.secondary)
            Text("Windy lives in your menu bar. Nothing on your screen moves until the end of this setup.")
                .foregroundStyle(.secondary)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow Accessibility").font(.title.bold())
            Text("macOS only lets an app move and resize other apps' windows once you allow it in System Settings › Privacy & Security › Accessibility. Windy uses it for window positions and sizes, nothing more.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open System Settings") {
                    Accessibility.prompt()
                    Accessibility.openSettings()
                }
                Label(trusted ? "Access granted" : "Waiting for access",
                      systemImage: trusted ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(trusted ? .green : .secondary)
            }
            if waited >= 10 {
                // The switch belongs to the copy of Windy it was turned on for: a different copy
                // (a new download, a rebuild) shows it on but isn't allowed until it's added again.
                Text("Switch already on? It may be for another copy of Windy. Select Windy in the list, remove it with −, then come back here and click Open System Settings again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Restart Windy", action: Accessibility.relaunch)
            }
            Toggle("Open Windy at login", isOn: $prefs.openAtLogin)
        }
    }

    private var choices: some View {
        Form {
            Picker("Layout", selection: $prefs.defaultLayout) {
                ForEach(LayoutKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Windows per screen", selection: $prefs.defaultCount) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Highlight the active window", selection: $prefs.highlight) {
                ForEach(Highlight.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Stack when the screen is full", isOn: $prefs.stackWhenFull)
        }
        .formStyle(.grouped)
    }
}

/// Windy's mark: four panes with a gust line, drawn in code so there are no image assets to ship.
enum WindyIcon {
    static func menuBar(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let panes = [
                CGRect(x: 2, y: 9.5, width: 6.5, height: 6.5), CGRect(x: 9.5, y: 9.5, width: 6.5, height: 6.5),
                CGRect(x: 2, y: 2, width: 6.5, height: 6.5), CGRect(x: 9.5, y: 2, width: 6.5, height: 6.5),
            ]
            NSColor.black.set()
            for pane in panes {
                let path = NSBezierPath(roundedRect: pane, xRadius: 1.8, yRadius: 1.8)
                if active { path.fill() } else { path.lineWidth = 1.2; path.stroke() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func app(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.06, dy: s * 0.06), xRadius: s * 0.22, yRadius: s * 0.22)
            NSGradient(starting: NSColor(hex: "#F6F1E7")!, ending: NSColor(hex: "#E7DFD0")!)!.draw(in: bg, angle: -90)
            let inner = rect.insetBy(dx: s * 0.2, dy: s * 0.2)
            let g = s * 0.04
            let w = (inner.width - g) / 2
            let colors = ["#1F2328", "#E4572E", "#1F2328", "#1F2328"]
            let origins = [CGPoint(x: inner.minX, y: inner.minY + w + g), CGPoint(x: inner.minX + w + g, y: inner.minY + w + g),
                           CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.minX + w + g, y: inner.minY)]
            for (o, c) in zip(origins, colors) {
                NSColor(hex: c)!.setFill()
                NSBezierPath(roundedRect: CGRect(origin: o, size: CGSize(width: w, height: w)), xRadius: s * 0.04, yRadius: s * 0.04).fill()
            }
            return true
        }
    }
}
