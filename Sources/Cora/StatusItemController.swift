import AppKit
import Combine
import CoraKit
import SwiftUI

/// The menu bar: the Cora mark (with a dot while agents work in any space) and the subscriptions the person pinned in
/// every space; the popover opens on click, on the space chosen last.
@MainActor
final class StatusItemController: NSObject {
    let spaces: Spaces
    private(set) var item: NSStatusItem
    let popover = NSPopover()
    var openWindow: (String?) -> Void = { _ in }
    private var observation: AnyCancellable?
    private var screensObservation: NSObjectProtocol?
    private var wakeObservation: NSObjectProtocol?
    private var displays: Set<CGDirectDisplayID>
    private var rebuilds: [DispatchWorkItem] = []
    private var displaysMoved = false

    init(spaces: Spaces) {
        self.spaces = spaces
        item = Self.makeItem()
        displays = Self.currentDisplays()
        super.init()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: SpacesPopover(spaces: spaces, openAgent: { [weak self] id in
            self?.popover.performClose(nil)
            self?.openWindow(id)
        }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        attach()
        observation = spaces.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.draw() } }
        screensObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        wakeObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged(woke: true) }
        }
    }

    /// The same name every time, so the menu bar keeps the place the person gave the item when it is made again.
    private static func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Item-0"
        return item
    }

    private static func currentDisplays() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
    }

    private func attach() {
        item.button?.target = self
        item.button?.action = #selector(toggle)
        draw()
    }

    /// macOS 27 leaves an item made before a display was plugged in (or woke with the Mac) off that display's menu
    /// bar: when the displays change, the item is made again so it shows on every one of them. The menu bar settles
    /// its displays a few seconds after the Mac does, so it is made again once soon and once when that is over.
    private func screensChanged(woke: Bool = false) {
        // A display unplugged and plugged back within the wait still counts: any different set seen on the way does.
        let now = Self.currentDisplays()
        if now != displays || woke { displays = now; displaysMoved = true }
        guard displaysMoved else { return }
        rebuilds.forEach { $0.cancel() }
        rebuilds = [2.0, 15.0].map { delay in
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.remakeItem() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
        displaysMoved = false
    }

    func remakeItem() {
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(item)
        item = Self.makeItem()
        attach()
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        let store = spaces.current
        Task { if let at = store.refreshedAt, Date().timeIntervalSince(at) > 30 { await store.refresh() } }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func draw() {
        guard let button = item.button else { return }
        let stores = spaces.visible
        let working = stores.reduce(0) { $0 + ($1.snapshot?.working.count ?? 0) }
        button.image = CoraMark.image(working: working)
        button.imagePosition = .imageLeading
        let parts = stores.flatMap { MenuBarTitle.parts($0) }
        button.attributedTitle = MenuBarTitle.attributed(parts)
        button.alphaValue = stores.contains { $0.phase == .ready } ? 1 : 0.55
        let lines = stores.compactMap { store in
            store.snapshot.map { snapshot in ([String(localized: "\(snapshot.space.name): \(snapshot.working.count) working")] + snapshot.pinned(store.pins).map(\.text)).joined(separator: "\n") }
        }
        button.toolTip = lines.isEmpty ? "Cora" : lines.joined(separator: "\n\n")
    }
}
