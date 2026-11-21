import SwiftUI
import CaptureKit

/// Settings (ADR 0036; mirrors S/SettingsActivity.kt): one switch per `FeatureFlags.prefKeys` entry (`SettingsEntries.all`),
/// stored as Bool `ck.*` in the UserDefaults suite `capturekit` (`Prefs.features`). Precedence at scan time stays
/// debug environment > this setting > default (`Prefs.flags()`); a change applies to the next scan.
struct SettingsView: View {
    private let entries = SettingsEntries.all
    @State private var values: [String: Bool] = {
        var v: [String: Bool] = [:]
        for e in SettingsEntries.all { v[e.key] = Prefs.features.object(forKey: e.key) as? Bool ?? e.defaultOn }
        return v
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RowGroup {
                    ForEach(Array(entries.enumerated()), id: \.element.key) { i, e in
                        if i > 0 { Divider().overlay(Theme.label3) }
                        InfoRow(title: e.title, subtitle: e.subtitle) {
                            Toggle(e.title, isOn: binding(e)).labelsHidden()
                        }
                    }
                }
                Text("Changes apply to the next scan.").font(.footnote).foregroundStyle(Theme.label3).frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .page()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    private func binding(_ e: SettingsEntries.Entry) -> Binding<Bool> {
        Binding(
            get: { values[e.key] ?? e.defaultOn },
            set: { on in
                values[e.key] = on
                Prefs.features.set(on, forKey: e.key)
            })
    }
}
