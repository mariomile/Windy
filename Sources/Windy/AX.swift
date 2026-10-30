import AppKit
import ApplicationServices

/// Private but stable for over a decade; every window manager on macOS relies on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func value(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { value(name) as? String }
    func bool(_ name: String) -> Bool { (value(name) as? Bool) ?? false }

    func element(_ name: String) -> AXUIElement? {
        guard let v = value(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var windows: [AXUIElement] { (value(kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let v = value(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    /// Frame in AX coordinates: origin at the top-left of the primary screen, y grows downward.
    var frame: CGRect? {
        var p = CGPoint.zero
        var s = CGSize.zero
        guard let pv = axValue(kAXPositionAttribute), AXValueGetValue(pv, .cgPoint, &p),
              let sv = axValue(kAXSizeAttribute), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    func setFrame(_ frame: CGRect) {
        var p = frame.origin
        var s = frame.size
        guard let pos = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return }
        // Size, position, size: a window moving to another screen can be clamped by the old one.
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, size)
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, size)
    }

    var isSizeSettable: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(self, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func set(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
