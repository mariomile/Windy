import AppKit
import Carbon.HIToolbox

/// Global shortcuts registered with macOS. Windy is told only when one of its own key
/// combinations is pressed, never about anything else you type.
@MainActor
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let keys = Unmanaged<HotKeys>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { keys.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, me, nil)
    }

    @discardableResult
    func register(_ keyCode: Int, _ modifiers: Int, _ action: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x5749_4E44, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return 0 }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ ids: [UInt32]) {
        for id in ids {
            if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
            actions[id] = nil
        }
    }

    func unregisterAll() { unregister(Array(refs.keys)) }
}

/// Carbon modifier masks and the symbols shown in the UI.
enum Keys {
    static func modifiers(_ prefix: ShortcutPrefix) -> Int {
        switch prefix {
        case .controlOption: controlKey | optionKey
        case .optionCommand: optionKey | cmdKey
        case .controlShift: controlKey | shiftKey
        }
    }

    /// The extra modifier for the window-count shortcuts (⌃⌥⌘1–5 by default).
    static func countModifier(_ prefix: ShortcutPrefix) -> (mask: Int, symbol: String) {
        prefix == .optionCommand ? (controlKey, "⌃") : (cmdKey, "⌘")
    }
}

/// Every shortcut Windy offers, for registration and for the Settings and menu bar lists.
struct Shortcut: Identifiable {
    let id: String
    let title: String
    let key: Int
    let keySymbol: String
    let extraShift: Bool
}

enum Shortcuts {
    static let all: [Shortcut] = [
        Shortcut(id: "focus", title: "Focus mode", key: kVK_ANSI_Z, keySymbol: "Z", extraShift: false),
        Shortcut(id: "noPeek", title: "No peek", key: kVK_ANSI_D, keySymbol: "D", extraShift: false),
        Shortcut(id: "clean", title: "Clean Space", key: kVK_ANSI_P, keySymbol: "P", extraShift: false),
        Shortcut(id: "left", title: "Swap or move left", key: kVK_LeftArrow, keySymbol: "←", extraShift: false),
        Shortcut(id: "right", title: "Swap or move right", key: kVK_RightArrow, keySymbol: "→", extraShift: false),
        Shortcut(id: "up", title: "Swap or move up", key: kVK_UpArrow, keySymbol: "↑", extraShift: false),
        Shortcut(id: "down", title: "Swap or move down", key: kVK_DownArrow, keySymbol: "↓", extraShift: false),
        Shortcut(id: "primary", title: "Make primary", key: kVK_Return, keySymbol: "↩", extraShift: false),
        Shortcut(id: "grow", title: "Make bigger", key: kVK_ANSI_Equal, keySymbol: "=", extraShift: false),
        Shortcut(id: "shrink", title: "Make smaller", key: kVK_ANSI_Minus, keySymbol: "-", extraShift: false),
        Shortcut(id: "reset", title: "Reset sizes", key: kVK_ANSI_0, keySymbol: "0", extraShift: false),
        Shortcut(id: "next", title: "Next window", key: kVK_ANSI_RightBracket, keySymbol: "]", extraShift: false),
        Shortcut(id: "prev", title: "Previous window", key: kVK_ANSI_LeftBracket, keySymbol: "[", extraShift: false),
        Shortcut(id: "stackNext", title: "Next in stack", key: kVK_ANSI_Grave, keySymbol: "`", extraShift: false),
        Shortcut(id: "stackPrev", title: "Previous in stack", key: kVK_ANSI_Grave, keySymbol: "`", extraShift: true),
        Shortcut(id: "float", title: "Float or tile window", key: kVK_ANSI_F, keySymbol: "F", extraShift: false),
    ]

    static let countKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]

    static func label(_ s: Shortcut, _ prefix: ShortcutPrefix) -> String {
        prefix.symbols + (s.extraShift && prefix != .controlShift ? "⇧" : "") + s.keySymbol
    }
}
