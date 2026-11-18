import AppKit
import Combine
import CoraKit
import SwiftUI

/// The menu bar: how many agents are working and the tightest quota left; the popover opens on click.
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
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store, openAgent: { [weak self] id in
            self?.popover.performClose(nil)
            self?.openWindow(id)
        }))
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
        let symbol = NSImage(systemSymbolName: working > 0 ? "person.2.wave.2.fill" : "person.2.wave.2", accessibilityDescription: "Cora")
        symbol?.isTemplate = true
        button.image = symbol
        button.imagePosition = .imageLeading
        var parts: [String] = []
        if working > 0 { parts.append("\(working)") }
        if let tight = store.snapshot?.tightest { parts.append(Format.percent(tight.window.remainingPercent)) }
        let text = parts.joined(separator: " · ")
        let color: NSColor
        switch store.snapshot?.tightest?.window.level {
        case .critical?: color = .systemRed
        case .warning?: color = .systemOrange
        default: color = .labelColor
        }
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color,
        ])
        button.alphaValue = store.phase == .ready ? 1 : 0.55
        button.toolTip = store.snapshot.map { "\($0.space.name): \(working) working" } ?? "Cora"
    }
}
