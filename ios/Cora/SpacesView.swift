import CoraKit
import SwiftUI

/// The spaces this iPhone reads, adding one, and signing this iPhone out of one.
struct SpacesView: View {
    @ObservedObject var spaces: Spaces
    @State private var adding = false
    @State private var leaving: SpaceStore?

    var body: some View {
        List {
            Section {
                ForEach(spaces.stores) { store in
                    Button { spaces.selected = store.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text("\(store.connection.host) · \(store.connection.userName)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.id == spaces.current?.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { leaving = store } label: { Label("Disconnect", systemImage: "link.badge.minus") }
                    }
                }
            } footer: {
                Text("You can follow work, answer questions and close plans you manage.")
            }
            Section { Button { adding = true } label: { Label("Add a space", systemImage: "plus") } }
            if let current = spaces.current {
                Section {
                    Button(role: .destructive) { leaving = current } label: { Label(String(localized: "Disconnect this iPhone from \(current.title)"), systemImage: "link.badge.minus") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Spaces")
        .sheet(isPresented: $adding) {
            NavigationStack {
                ConnectView(spaces: spaces, done: { adding = false })
                    .navigationTitle("Add a space").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } } }
            }
        }
        .confirmationDialog(leaving.map { String(localized: "Disconnect this iPhone from \($0.title)?") } ?? "", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { if let store = leaving { Task { await spaces.signOut(store) } }; leaving = nil }
        }
    }
}

/// The address of a space and the button that opens its panel to authorize this iPhone.
struct ConnectView: View {
    @ObservedObject var spaces: Spaces
    var done: () -> Void = {}

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image("Mark").resizable().scaledToFit().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    Text("Connect a Cora space").font(.title3.weight(.semibold))
                    Text("Sign in to the panel of your space and authorize this iPhone: you will see your agents, their quotas and what they are doing now.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("Space address") {
                TextField(String(localized: "Space address"), text: $spaces.address, prompt: Text(verbatim: "yourspace.usecora.space"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).onSubmit { spaces.authorize() }
            }
            Section {
                Button {
                    spaces.authorize()
                } label: {
                    HStack {
                        Text("Connect").font(.body.weight(.semibold))
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
                if let line = statusLine { Text(line.text).font(.footnote).foregroundStyle(line.error ? Color.red : Color.secondary) }
            } footer: {
                Text("You can follow work, answer questions and close plans you manage.")
            }
        }
        .onChange(of: spaces.stores.count) { _, _ in done() }
    }

    var busy: Bool {
        switch spaces.pairing {
        case .waiting, .connecting: return true
        default: return false
        }
    }

    var statusLine: (text: String, error: Bool)? {
        switch spaces.pairing {
        case .idle: return nil
        case .waiting(let host): return (String(localized: "Authorize this iPhone in the panel of \(host)."), false)
        case .connecting: return (String(localized: "Connecting…"), false)
        case .failed(let message): return (message, true)
        }
    }
}
