import SwiftUI

/// M0 diagnostic window: proves the engine links, the database opens, and migrations run.
/// Replaced by the real shell once the UI spec lands.
struct PlaceholderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("DuckDB", value: model.engineVersion.isEmpty ? "—" : model.engineVersion)
            }
            Section("App database") {
                LabeledContent("Path", value: model.databasePath)
                    .textSelection(.enabled)
                LabeledContent("Schema version", value: String(model.schemaVersion))
                LabeledContent("Applied this launch",
                               value: model.migrationsAppliedThisLaunch.isEmpty
                                   ? "none (already current)"
                                   : model.migrationsAppliedThisLaunch.map(String.init).joined(separator: ", "))
            }
            Section("Tables") {
                if model.tables.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    ForEach(model.tables, id: \.self) { Text($0).monospaced() }
                }
            }
            Section("Status") {
                switch model.phase {
                case .opening:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Opening…") }
                case .ready:
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ArcGIS Explorer")
    }
}
