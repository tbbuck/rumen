import SwiftUI
import RumenKit

/// Pasted URL → resolved node preview + friendly name → Add.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    let pending: PendingAdd
    @State private var friendlyName = ""
    @State private var advanced = false
    @State private var cookie = ""
    @State private var origin = ""
    @State private var referer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a server").font(.sheetDisplay(18))
            Text(pending.preview).font(.sheetUI(13)).foregroundStyle(Palette.ink).frame(maxWidth: 440, alignment: .leading)
            Text(pending.rootURL.absoluteString).font(.sheetMono(12)).foregroundStyle(Palette.muted).lineLimit(2).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 6) {
                Caption("Friendly name")
                TextField(pending.rootURL.host ?? "Name", text: $friendlyName)
                    .textFieldStyle(SheetFieldStyle())
                    .accessibilityLabel("Friendly name")
                    .onSubmit { Task { await add() } }
            }
            Button(advanced ? "Hide advanced" : "Advanced…") { advanced.toggle() }.buttonStyle(LinkButtonStyle(size: 12.5))
            if advanced {
                AdvancedServerFields(cookie: $cookie, origin: $origin, referer: $referer, rootURL: pending.rootURL)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingAdd = nil }.buttonStyle(LinkButtonStyle())
                AsyncButton("Add", busy: "Adding…", action: add).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add a server")
        .onAppear { friendlyName = pending.rootURL.host ?? "" }
    }

    private func add() async {
        await model.addServer(pending, friendlyName: friendlyName, cookie: cookie, origin: origin, referer: referer)
    }
}

/// Friendly name, Origin and Referer overrides (defaults shown greyed), auth kind.
struct ServerSettingsSheet: View {
    @Environment(AppModel.self) private var model
    let server: ServerRecord
    @State private var name = ""
    @State private var origin = ""
    @State private var referer = ""
    @State private var cookie = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server settings").font(.sheetDisplay(18))
            Text(server.rootURL.absoluteString).font(.sheetMono(12)).foregroundStyle(Palette.muted)
            field("Friendly name", text: $name, placeholder: server.host)
            AdvancedServerFields(cookie: $cookie, origin: $origin, referer: $referer, rootURL: server.rootURL)
            VStack(alignment: .leading, spacing: 6) {
                Caption("Sign-in")
                Caption("Token sign-in is not built yet. For a server behind a login, paste a signed-in browser's Cookie above.", size: 12.5, color: Palette.muted2)
                    .frame(maxWidth: 440, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.settingsServer = nil }.buttonStyle(LinkButtonStyle())
                AsyncButton("Save", busy: "Saving…") {
                    await model.saveSettings(server, name: name.isEmpty ? server.host : name, origin: origin, referer: referer, cookie: cookie)
                    model.settingsServer = nil
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server settings")
        .onAppear {
            name = server.friendlyName
            origin = server.originOverride ?? ""
            referer = server.refererOverride ?? ""
            cookie = server.cookie ?? ""
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(label)
            TextField(placeholder, text: text).textFieldStyle(SheetFieldStyle(mono: mono)).accessibilityLabel(label)
        }
    }
}

/// Cookie plus the Origin and Referer overrides: the same block on the add sheet (under
/// "Advanced…") and on server settings.
struct AdvancedServerFields: View {
    @Binding var cookie: String
    @Binding var origin: String
    @Binding var referer: String
    let rootURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Caption("Cookie")
                TextField("name=value; other=value", text: $cookie).textFieldStyle(SheetFieldStyle(mono: true)).accessibilityLabel("Cookie")
                Caption("Sent as the Cookie header on every request to this server, like curl -b. Kept in your login keychain, not in the app database.", size: 11.5, color: Palette.muted2)
                    .frame(maxWidth: 440, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                Caption("Origin header")
                TextField(ServerHeaders.resolve(rootURL: rootURL).origin, text: $origin).textFieldStyle(SheetFieldStyle(mono: true)).accessibilityLabel("Origin header")
            }
            VStack(alignment: .leading, spacing: 6) {
                Caption("Referer header")
                TextField(ServerHeaders.resolve(rootURL: rootURL).referer, text: $referer).textFieldStyle(SheetFieldStyle(mono: true)).accessibilityLabel("Referer header")
            }
            Caption("Leave a header blank to use the default shown. Both are sent on every request to this server.", size: 11.5, color: Palette.muted2)
                .frame(maxWidth: 440, alignment: .leading)
        }
    }
}

/// Known servers by last visit, with rename, re-crawl, forget; "Add a server".
struct RecentServersPopover: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForget: ServerRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.servers) { server in
                HStack(spacing: 10) {
                    Button {
                        model.showRecents = false
                        Task { await model.selectServer(server.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.friendlyName).font(.sheetUI(13, model.currentServer?.id == server.id ? .semibold : .regular))
                                .foregroundStyle(Palette.ink)
                            Text("\(server.host), visited \(Age.text(server.lastVisitedAt))").font(.sheetUI(11)).foregroundStyle(Palette.muted2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button("Rename…") { model.showRecents = false; model.settingsServer = server }
                        Button("Re-crawl") {
                            model.showRecents = false
                            Task { await model.selectServer(server.id); await model.refreshCurrent() }
                        }
                        Divider()
                        Button("Forget…") { confirmForget = server }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Palette.muted)
                    }
                    .menuStyle(.button).buttonStyle(.borderless)
                    .frame(width: 20)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
            HStack(spacing: 16) {
                Button("Add a server…") {
                    model.showRecents = false
                    model.beginURLEdit()
                }
                .buttonStyle(LinkButtonStyle())
                Button("Start page") {
                    model.showRecents = false
                    model.showStartPage()
                }
                .buttonStyle(LinkButtonStyle())
            }
            .padding(12)
        }
        .frame(width: 320)
        .background(Palette.panel)
        .confirmationDialog("Forget \(confirmForget?.friendlyName ?? "")?", isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } })) {
            Button("Forget", role: .destructive) {
                if let server = confirmForget { Task { await model.forget(server) } }
                confirmForget = nil
                model.showRecents = false
            }
        } message: {
            Text("Cached metadata for this server is removed. Downloaded files on disk are kept.")
        }
    }
}
