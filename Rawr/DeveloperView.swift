import SwiftUI
import UniformTypeIdentifiers

struct DeveloperView: View {
    @StateObject private var rawrKit = RawrKit()
    @State private var selectedImageURL: URL?
    @State private var selectedImageName: String = "No image selected"
    @State private var showingFilePicker = false
    @State private var selectedLogLevel: LogLevel = .info

    var body: some View {
        HSplitView {
            // Left Panel - Controls and Image Input
            VStack(alignment: .leading, spacing: 16) {
                controlsSection
                imageInputSection
                testingControlsSection
            }
            .frame(minWidth: 300, maxWidth: 400)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            // Center Panel - Input Image Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Input Image")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)

                if let previewImage = rawrKit.previewImage {
                    ImagePreviewView(image: previewImage)
                } else {
                    PlaceholderView(text: "No image loaded")
                }
            }
            .frame(minWidth: 300)
            .background(Color(NSColor.textBackgroundColor))

            // Right Panel - Processed Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Processed Preview")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)

                if let processedPreview = rawrKit.processedPreviewImage {
                    ImagePreviewView(image: processedPreview)
                } else {
                    PlaceholderView(text: "No processed image")
                }
            }
            .frame(minWidth: 300)
            .background(Color(NSColor.textBackgroundColor))

            // Bottom Panel - Information Display
            VStack(spacing: 0) {
                performanceSection
                logSection
            }
            .frame(minWidth: 300, maxWidth: 400)
        }
        .navigationTitle("RawrKit Developer Interface")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private var controlsSection: some View {
        GroupBox("RawrKit Controls") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Status:")
                        .fontWeight(.medium)
                    Spacer()
                    StatusIndicator(isProcessing: rawrKit.isProcessing)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Actions")
                        .font(.headline)

                    Button("Initialize RawrKit") {
                        rawrKit.log("Reinitializing RawrKit...", level: .info)
                    }

                    Button("Clear Logs") {
                        rawrKit.logs.removeAll()
                    }

                    Button("Test Error") {
                        rawrKit.log("This is a test error message", level: .error)
                    }

                    Button("Test Warning") {
                        rawrKit.log("This is a test warning message", level: .warning)
                    }
                }
            }
            .padding(8)
        }
    }

    private var imageInputSection: some View {
        GroupBox("Image Input") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Selected:")
                        .fontWeight(.medium)
                    Text(selectedImageName)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Select Image File") {
                    showingFilePicker = true
                }
                .buttonStyle(.bordered)

                if selectedImageURL != nil {
                    Button("Process Image") {
                        Task {
                            if let url = selectedImageURL {
                                let success = await rawrKit.loadRawFile(from: url)
                                if success {
                                    await rawrKit.invertImage()
                                }
                                rawrKit.log("Processing result: \(success ? "Success" : "Failed")")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rawrKit.isProcessing)
                }
            }
            .padding(8)
        }
    }

    private var testingControlsSection: some View {
        GroupBox("Testing Controls") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Performance Tests")
                    .font(.headline)

                Button("Run Performance Test") {
                    Task {
                        rawrKit.log("Starting performance test...", level: .info)
                        // Create a test image URL
                        if let testURL = Bundle.main.url(forResource: "test", withExtension: "jpg") {
                            let success = await rawrKit.loadRawFile(from: testURL)
                            if success {
                                await rawrKit.invertImage()
                            }
                        }

                        if let duration = rawrKit.performance.duration {
                            rawrKit.log("Performance test completed in \(String(format: "%.2f", duration))s", level: .info)
                        }
                    }
                }
                .disabled(rawrKit.isProcessing)

                Button("Memory Stress Test") {
                    Task {
                        rawrKit.log("Starting memory stress test...", level: .warning)
                        rawrKit.log("Memory stress test placeholder - implement with actual images", level: .info)
                    }
                }
                .disabled(rawrKit.isProcessing)
            }
            .padding(8)
        }
    }

    private var performanceSection: some View {
        GroupBox("Performance Metrics") {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    MetricRow(label: "Last Duration", value: formatDuration(rawrKit.performance.duration))
                    MetricRow(label: "Processing", value: rawrKit.isProcessing ? "Active" : "Idle")
                    MetricRow(label: "Total Logs", value: "\(rawrKit.logs.count)")
                }
                Spacer()
            }
            .padding(8)
        }
        .padding(.horizontal)
        .padding(.top)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs")
                    .font(.headline)

                Spacer()

                Picker("Log Level Filter", selection: $selectedLogLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredLogs) { log in
                            LogEntryView(entry: log)
                                .id(log.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: rawrKit.logs.count) {
                    if let lastLog = rawrKit.logs.last {
                        withAnimation {
                            proxy.scrollTo(lastLog.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
    }

    private var filteredLogs: [LogEntry] {
        rawrKit.logs.filter { log in
            switch selectedLogLevel {
            case .debug: return true
            case .info: return log.level != .debug
            case .warning: return log.level == .warning || log.level == .error
            case .error: return log.level == .error
            }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            selectedImageURL = url
            selectedImageName = url.lastPathComponent
            rawrKit.log("Selected image file: \(url.lastPathComponent)")

        case .failure(let error):
            rawrKit.log("File picker error: \(error.localizedDescription)", level: .error)
        }
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration = duration else { return "N/A" }
        return String(format: "%.3fs", duration)
    }

}

struct StatusIndicator: View {
    let isProcessing: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(isProcessing ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            Text(isProcessing ? "Processing" : "Ready")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .fontWeight(.medium)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct LogEntryView: View {
    let entry: LogEntry

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(entry.level.color)
                .frame(width: 60, alignment: .leading)

            Text(entry.message)
                .font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(
            Rectangle()
                .fill(entry.level == .error ? Color.red.opacity(0.1) :
                      entry.level == .warning ? Color.orange.opacity(0.1) :
                      Color.clear)
        )
    }
}

struct ImagePreviewView: View {
    let image: CGImage

    var body: some View {
        GeometryReader { geometry in
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }
}

struct PlaceholderView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(text)
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Spacer()
        }
        .padding()
    }
}

#Preview {
    DeveloperView()
        .frame(width: 1000, height: 700)
}