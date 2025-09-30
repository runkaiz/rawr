# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rawr is a macOS document-based SwiftUI application that is a node based RAW file editor. It targets both digital and film photographer and seeks to help them automate parts of their photo editting workflow.

## Architecture

### Core Principle: Rawr is just the frontend, RawrKit is the backend

**CRITICAL**: All important logic must be implemented in RawrKit, not in the main app. The Rawr app is purely a UI layer.

### Core Components

- **RawrApp.swift**: Main app entry point using DocumentGroup pattern with minimum window size constraints (900x700)
- **RawrDocument.swift**: Document model conforming to FileDocument protocol, handles custom `.flow` file type (`xyz.runkaizhang.flow`)
- **ContentView.swift**: Main UI views - should ONLY handle presentation and user interaction
- **RawrKit/**: Framework/library directory - ALL business logic goes here
  - **RawrKit handles ALL important operations including:**
    - Security-scoped resource access (via `loadRawFile()` in Source.swift)
    - Security-scoped bookmark creation and resolution
    - Image loading and processing
    - File I/O operations
    - RAW file decoding
    - Image format conversions
    - All computational/processing logic
  - **Published properties for UI binding:**
    - `previewImage: CGImage?` - The loaded image preview for display
    - `processedPreviewImage: CGImage?` - The processed image preview for display
    - `isProcessing: Bool` - Processing state
    - `logs: [LogEntry]` - Log entries for debugging
    - `performance: PerformanceMetrics` - Performance metrics
  - **Static utility methods:**
    - `RawrKit.createSecurityBookmark(for: URL) -> Data?` - Creates security-scoped bookmark for file persistence
  - **Instance methods:**
    - `loadRawFile(from: URL) async -> Bool` - Loads and processes RAW files with security-scoped access
    - `resolveBookmark(_: Data) -> URL?` - Resolves security-scoped bookmarks with logging
    - `invertImage() async -> Bool` - Applies film negative inversion processing
  - **DO NOT implement any of the following in the main app:**
    - Direct file access with `NSImage(contentsOf:)` or `Data(contentsOf:)`
    - Image processing or manipulation
    - Security-scoped resource handling
    - RAW file decoding
    - Any business logic
  - **Main app responsibilities:**
    - Display RawrKit's published images (previewImage, processedPreviewImage)
    - Call RawrKit methods (loadRawFile, invertImage, etc.)
    - Provide UI for node graph editing
    - Pass URLs to RawrKit for processing
    - Bind to RawrKit's published properties for reactive UI updates

### Document System

The app uses a custom document type system:
- File extension: `.exampletext` (as defined in Info.plist, though code references `.flow`)
- UTType identifier: `xyz.runkaizhang.flow` (in code) vs `com.example.plain-text` (in Info.plist)
- Document handling through SwiftUI's FileDocument protocol

## Development Commands

### Building
```bash
# Build the app
xcodebuild -scheme Rawr -configuration Debug build

# Build for release
xcodebuild -scheme Rawr -configuration Release build
```

### Testing
Building for compilation errors is allowed, but running the app will be up to the developer when testing any feature that requires interactivity.
```

### Available Targets
- `Rawr` - Main application
- `RawrTests` - Unit tests (uses Swift Testing framework)
- `RawrUITests` - UI tests

## Key Configuration

- **Bundle ID**: `xyz.runkaizhang.Rawr`
- **Deployment Target**: macOS 15.4
- **Swift Version**: 5.0
- **Development Team**: C58CLY4K2U
- **Testing Framework**: Swift Testing (new testing framework, not XCTest)

## Development Notes

### File Type Discrepancy
There's an inconsistency between the document type definitions:
- Code defines UTType as `xyz.runkaizhang.flow`
- Info.plist defines it as `com.example.plain-text` with `.exampletext` extension

### Metal/MetalKit Integration
ContentView imports Metal and MetalKit frameworks, suggesting the app may be intended for graphics/rendering work, though no implementation is present yet.

### Current State
The application is in early development with minimal implementation - most views and functionality are stubbed out.

## Implementation Guidelines

### When implementing new features:

1. **Always consider RawrKit first**: Ask yourself "Should this logic be in RawrKit?" The answer is almost always YES if it involves:
   - File operations
   - Image processing
   - Computation
   - State management of image data
   - Security-scoped resources

2. **RawrKit API pattern**:
   ```swift
   // In RawrKit: Expose published properties
   @Published public var someResult: CGImage?

   // In RawrKit: Provide async methods
   public func processImage(from url: URL) async -> Bool

   // In Main App: Create RawrKit instance
   @StateObject private var rawrKit = RawrKit()

   // In Main App: Call methods and display results
   .task {
       await rawrKit.loadRawFile(from: url)
   }
   Image(nsImage: NSImage(cgImage: rawrKit.previewImage, ...))
   ```

3. **Always update CLAUDE.md** when new functionality is added to RawrKit, documenting:
   - New public methods
   - New published properties
   - Expected usage patterns