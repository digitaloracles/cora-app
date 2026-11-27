import AppKit
import Combine
import CoraKit
import SwiftUI

/// The menu bar: the Cora mark (with a dot while agents work in any space) and the subscriptions the person pinned in
/// every space; the popover opens on click, on the space chosen last.
@MainActor
final class StatusItemController: NSObject {
    let spaces: Spaces
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var openWindow: (String?) -> Void = { _ in }
    var createLocal: () -> Void = {}
    private var observation: AnyCancellable?

    init(spaces: Spaces) {
        self.spaces = spaces
        super.init()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: SpacesPopover(spaces: spaces, openAgent: { [weak self] id in
            self?.popover.performClose(nil)
            self?.openWindow(id)
        }, createLocal: { [weak self] in
            self?.popover.performClose(nil)
            self?.createLocal()
        }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        item.button?.target = self
        item.button?.action = #selector(toggle)
        draw()
        observation = spaces.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.draw() } }
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
