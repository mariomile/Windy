import AppKit

// A client that hangs up early must not take Windy down: writes to it just fail.
signal(SIGPIPE, SIG_IGN)

// With arguments this binary is the `windy` command; without, it's the menu bar app.
if CLI.isCommand(CommandLine.arguments) {
    exit(CLI.run(CommandLine.arguments))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
