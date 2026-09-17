import SwiftUI
import AppKit
import ArcGISKit

/// What the Download tab starts from and the limits the network layer runs with (M9), kept
/// in the app database's `setting` table. Appearance lives beside it on the model.
struct Preferences: Equatable {
    var downloadDirectory: URL
    var defaultFormat: ExportFormat = .geoParquet
    var defaultWGS84 = false
    var domainLabels = false
    /// Requests in flight per host, shared by crawl, query, and download (SPEC §6.2).
    var concurrency = 4
    /// Attempts per request before a transient failure is given up on.
    var retryAttempts = 5

    static var initialDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArcGIS Explorer", isDirectory: true)
    }

    /// The download's spatial reference for a layer: WGS 84 when preferred or when the format
    /// requires it, else the layer's own.
    func outWkid(for layer: LayerRecord) -> Int {
        defaultWGS84 || defaultFormat.forcesWGS84 ? 4326 : (layer.effectiveWkid ?? 4326)
    }

    var retryPolicy: RetryPolicy { RetryPolicy(maxAttempts: retryAttempts) }

    // MARK: Settings rows

    static let directoryKey = "download_dir"
    static let formatKey = "default_format"
    static let wgs84Key = "default_wgs84"
    static let labelsKey = "domain_labels"
    static let concurrencyKey = "concurrency"
    static let retryKey = "retry_attempts"

    /// Reads every preference from the settings table; a missing or unreadable row keeps the default.
    static func load(from database: AppDatabase) async throws -> Preferences {
        var p = Preferences(downloadDirectory: initialDirectory)
        if let dir = try await database.setting(directoryKey) { p.downloadDirectory = URL(fileURLWithPath: dir) }
        if let raw = try await database.setting(formatKey), let format = ExportFormat(rawValue: raw) { p.defaultFormat = format }
        if let raw = try await database.setting(wgs84Key) { p.defaultWGS84 = raw == "1" }
        if let raw = try await database.setting(labelsKey) { p.domainLabels = raw == "1" }
        if let raw = try await database.setting(concurrencyKey), let n = Int(raw) { p.concurrency = min(16, max(1, n)) }
        if let raw = try await database.setting(retryKey), let n = Int(raw) { p.retryAttempts = min(10, max(1, n)) }
        return p
    }

    func save(to database: AppDatabase) async throws {
        try await database.save(self)
    }
}

extension AppDatabase {
    func save(_ preferences: Preferences) throws {
        let downloadDirectory = preferences.downloadDirectory
        let defaultFormat = preferences.defaultFormat
        let defaultWGS84 = preferences.defaultWGS84
        let domainLabels = preferences.domainLabels
        let concurrency = preferences.concurrency
        let retryAttempts = preferences.retryAttempts
        try setSetting(Preferences.directoryKey, downloadDirectory.path)
        try setSetting(Preferences.formatKey, defaultFormat.rawValue)
        try setSetting(Preferences.wgs84Key, defaultWGS84 ? "1" : "0")
        try setSetting(Preferences.labelsKey, domainLabels ? "1" : "0")
        try setSetting(Preferences.concurrencyKey, String(concurrency))
        try setSetting(Preferences.retryKey, String(retryAttempts))
    }
}

/// The Preferences window (⌘,): download folder, default format and spatial reference,
/// domain labels, per-host concurrency, retry limit, appearance.
struct PreferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Downloads") {
                row("Folder") {
                    HStack(spacing: 12) {
                        Text(model.preferences.downloadDirectory.path).font(.sheetMono(12)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Change…") { model.chooseDownloadDirectory() }.buttonStyle(LinkButtonStyle(size: 12.5))
                        Button("Reveal") { model.reveal(model.preferences.downloadDirectory.path) }.buttonStyle(LinkButtonStyle(size: 12.5))
                    }
                }
                row("Format") {
                    Picker("", selection: binding(\.defaultFormat)) {
                        ForEach(ExportFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
                }
                row("Spatial reference") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: binding(\.defaultWGS84)) {
                            Text("The layer's own").tag(false)
                            Text("WGS 84").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
                        .disabled(model.preferences.defaultFormat.forcesWGS84)
                        if model.preferences.defaultFormat.forcesWGS84 {
                            Caption("GeoJSON is always WGS 84 (RFC 7946).", size: 11.5, color: Palette.muted2)
                        }
                    }
                }
                row("Domain labels") {
                    Toggle("Add a <field>_label column beside each coded-value field", isOn: binding(\.domainLabels))
                        .toggleStyle(.checkbox).font(.sheetUI(12.5))
                }
                Caption("Each download's tab starts from these and can change them for that run.", size: 11.5, color: Palette.muted2)
            }
            section("Network") {
                row("Requests per host") {
                    Stepper(value: binding(\.concurrency), in: 1...16) {
                        Text("\(model.preferences.concurrency)").font(.sheetMono(12.5)).foregroundStyle(Palette.ink).frame(width: 24, alignment: .trailing)
                    }
                }
                row("Attempts per request") {
                    Stepper(value: binding(\.retryAttempts), in: 1...10) {
                        Text("\(model.preferences.retryAttempts)").font(.sheetMono(12.5)).foregroundStyle(Palette.ink).frame(width: 24, alignment: .trailing)
                    }
                }
                Caption("Crawls, queries, and downloads share the per-host cap. Retries back off with jitter; a token error never retries.", size: 11.5, color: Palette.muted2)
                    .frame(maxWidth: 400, alignment: .leading)
            }
            section("Appearance") {
                Picker("", selection: Binding(get: { model.appearanceOverride }, set: { model.setAppearance($0) })) {
                    Text("Day").tag(ColorScheme?.some(.light))
                    Text("Night").tag(ColorScheme?.some(.dark))
                    Text("System").tag(ColorScheme?.none)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Palette.accent)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Palette.panel)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { model.preferences[keyPath: keyPath] },
                set: { value in
                    var next = model.preferences
                    next[keyPath: keyPath] = value
                    Task { await model.setPreferences(next) }
                })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.sheetUI(12.5)).foregroundStyle(Palette.muted).frame(width: 136, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
