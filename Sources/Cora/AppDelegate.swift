import AppKit
import CoraKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let spaces = Spaces()
    let selection = LiveSelection()
    var status: StatusItemController?
    var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Links can arrive before the app has finished launching: the panel opens Cora with them.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(spaces: spaces)
        status?.openWindow = { [weak self] id in self?.showWindow(agent: id) }
        spaces.start()
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        spaces.handle(url)
        if let button = status?.item.button, status?.popover.isShown == false {
            status?.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showWindow(agent: String?) {
        let store = spaces.current
        if let agent { selection.show(agent) } else if selection.agentId == nil { selection.agentId = store.snapshot?.working.first?.id ?? store.snapshot?.agents.first?.id }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = store.snapshot?.space.name ?? "Cora"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SpacesWindow(spaces: spaces, selection: selection, title: { [weak window] in window?.title = $0 }))
            window.setFrameAutosaveName("CoraLiveWindow")
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
        }
    }
}
