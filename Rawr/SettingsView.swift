//
//  SettingsView.swift
//  Rawr
//
//  Created by Runkai Zhang on 10/1/25.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsView()
            }
        }
        .scenePadding()
        .frame(minWidth: 400, minHeight: 200)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("showLogs") private var showLogs = true

    var body: some View {
        Form {
            Section {
                Toggle("Show Logs", isOn: $showLogs)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
