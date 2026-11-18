import AppKit
import CoraKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if let command = CLI.command(arguments) {
    let finished = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task { @MainActor in
        code = await CLI.run(command)
        finished.signal()
    }
    while finished.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(code)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
