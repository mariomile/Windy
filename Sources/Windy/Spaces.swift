import AppKit

// macOS has no public API for Spaces. These read-only calls are the ones yabai and other
// window managers use; they need no extra permission and don't touch System Integrity Protection.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ connection: Int32, _ display: CFString) -> UInt64

/// A display on one Space: each gets its own tiles, so coming back to a Space finds them as you left them.
struct ScreenKey: Hashable {
    let display: String
    let space: UInt64
}

extension NSScreen {
    /// The Space showing on this display right now.
    var currentSpace: UInt64 {
        let connection = CGSMainConnectionID()
        let space = CGSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
        return space != 0 ? space : CGSGetActiveSpace(connection)
    }

    var key: ScreenKey { ScreenKey(display: uuid, space: currentSpace) }
}
