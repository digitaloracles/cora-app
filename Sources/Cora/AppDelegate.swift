import AppKit
import CoraKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let spaces = Spaces()
    let local = LocalSpaceController()
    lazy var panel = PanelModel(spaces: spaces, local: local)
    var status: StatusItemController?
    var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Links can arrive before the app has finished launching: the panel opens Cora with them.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(spaces: spaces)
        status?.openWindow = { [weak self] id in self?.showWindow(agent: id) }
        local.onConnect = { [weak self] link in self?.spaces.handle(link) }
        spaces.start()
        Task { await local.ensureRunning() }
        // The first launch has no space yet: the window asks where it runs.
        if !local.exists && Storage.loadConnections().isEmpty { showWindow(agent: nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(agent: nil) }
        return true
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        spaces.handle(url)
        if let button = status?.item.button, status?.popover.isShown == false, panel.screen != .connectRemote {
            status?.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// The window: the panel of a space in the app's own browser, or the first-launch choice.
    func showWindow(agent: String?) {
        if window == nil {
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
            let size = NSSize(width: min(1180, screen.width - 40), height: min(780, screen.height - 30))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Cora"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: PanelWindowView(model: panel))
            // The window keeps its own size: SwiftUI only sets the minimum.
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.setContentSize(size)
            if !window.setFrameUsingName("CoraPanelWindow") { window.center() }
            window.setFrameAutosaveName("CoraPanelWindow")
            self.window = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
            }
        }
        if agent != nil || panel.screen == .panel && panel.browser.web.url == nil { panel.showAgent(agent) }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
