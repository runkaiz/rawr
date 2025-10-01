//
//  RawrApp.swift
//  Rawr
//
//  Created by Runkai Zhang on 4/29/25.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct RawrApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: RawrDocument()) { file in
            ContentView(document: file.$document)
                .frame(minWidth: 900, minHeight: 700)
                .navigationTitle("Rawr Editor")
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    func openRAWImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .dng, UTType("public.camera-raw-image")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }

            // For sandboxed apps, we need to access the security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }

                // Open the file in a new window
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error = error {
                        print("Error opening document: \(error)")
                    }
                }
            }
        }
    }
}
