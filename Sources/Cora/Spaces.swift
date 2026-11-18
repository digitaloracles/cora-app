import AppKit
import Combine
import CoraKit
import Foundation

/// Every space this Mac reads, each with its own store, token and live stream; one of them is on screen.
@MainActor
final class Spaces: ObservableObject {
    @Published private(set) var stores: [SpaceStore] = []
    /// The space on screen in the popover and the window.
    @Published private(set) var current: SpaceStore
    /// A space being added: its address and the panel's authorization, until it connects.
    @Published private(set) var adding: SpaceStore?
    private var watchers: [ObjectIdentifier: AnyCancellable] = [:]
    private let selectedKey = "selectedSpace"

    init(stores: [SpaceStore] = []) {
        let list = stores.isEmpty ? [SpaceStore()] : stores
        current = list[0]
        self.stores = stores
        list.forEach(watch)
    }

    func start() {
        let saved = Storage.loadConnections()
        guard !saved.isEmpty else { stores = []; watch(current); current.start(); return }
        stores = saved.map { SpaceStore(connection: $0) }
        stores.forEach(watch)
        let selected = UserDefaults.standard.string(forKey: selectedKey)
        current = stores.first { $0.connection?.server.absoluteString == selected } ?? stores[0]
        stores.forEach { $0.start() }
    }

    /// The stores the menu bar and the switchers show: the connected spaces, or the one waiting to connect.
    var visible: [SpaceStore] { stores.isEmpty ? [current] : stores }

    func select(_ store: SpaceStore) {
        current = store
        if let server = store.connection?.server { UserDefaults.standard.set(server.absoluteString, forKey: selectedKey) }
    }

    /// Shows the address field for one more space; the spaces already connected keep running.
    func beginAdding() {
        guard !stores.isEmpty else { return }
        let store = adding ?? SpaceStore()
        store.spaceInput = ""
        watch(store)
        adding = store
        current = store
    }

    func cancelAdding() {
        guard let adding else { return }
        self.adding = nil
        if current === adding { current = stores.first ?? SpaceStore() }
    }

    /// A `cora://connect` link goes to the space it belongs to, or to the one being added, or starts a new one.
    func handle(_ url: URL) {
        let server = (try? ConnectLink.parse(url))?.server
        if let server, let known = stores.first(where: { $0.connection?.server == server }) {
            select(known); known.handle(url); return
        }
        if let adding { current = adding; adding.handle(url); return }
        if stores.isEmpty { current.handle(url); return }
        beginAdding()
        adding?.handle(url)
    }

    /// Wires a store to the list: its changes reach the views, its pairing and disconnection change the list.
    private func watch(_ store: SpaceStore) {
        store.onConnected = { [weak self] store in self?.connected(store) }
        store.onDisconnected = { [weak self] store in self?.removed(store) }
        watchers[ObjectIdentifier(store)] = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func connected(_ store: SpaceStore) {
        if adding === store { adding = nil }
        if let server = store.connection?.server, let twin = stores.first(where: { $0 !== store && $0.connection?.server == server }) {
            twin.stop(); stores.removeAll { $0 === twin }
        }
        if !stores.contains(where: { $0 === store }) { stores.append(store) }
        select(store)
    }

    private func removed(_ store: SpaceStore) {
        stores.removeAll { $0 === store }
        guard current === store, let next = stores.first else {
            if current !== store { watchers[ObjectIdentifier(store)] = nil }
            return
        }
        watchers[ObjectIdentifier(store)] = nil
        select(next)
    }
}
