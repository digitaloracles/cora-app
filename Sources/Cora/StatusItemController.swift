import AppKit
import Combine
import CoraKit
import SwiftUI

/// The menu bar: the Cora mark (with a dot while agents work) and the subscriptions the person pinned; the popover opens on click.
@MainActor
final class StatusItemController: NSObject {
    let store: SpaceStore
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var openWindow: (String?) -> Void = { _ in }
    private var observation: AnyCancellable?

    init(store: SpaceStore) {
        self.store = store
        super.init()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: PopoverView(store: store, openAgent: { [weak self] id in
            self?.popover.performClose(nil)
            self?.openWindow(id)
        }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        item.button?.target = self
        item.button?.action = #selector(toggle)
        draw()
        observation = store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.draw() } }
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        Task { if let at = store.refreshedAt, Date().timeIntervalSince(at) > 30 { await store.refresh() } }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func draw() {
        guard let button = item.button else { return }
        let working = store.snapshot?.working.count ?? 0
        button.image = CoraMark.image(working: working)
        button.imagePosition = .imageLeading
        let parts = MenuBarTitle.parts(store)
        button.attributedTitle = MenuBarTitle.attributed(parts)
        button.alphaValue = store.phase == .ready ? 1 : 0.55
        button.toolTip = store.snapshot.map { snapshot in ([String(localized: "\(snapshot.space.name): \(working) working")] + snapshot.pinned(store.pins).map(\.text)).joined(separator: "\n") } ?? "Cora"
    }
}
