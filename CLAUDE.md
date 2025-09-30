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
    - **Node graph execution with Metal GPU acceleration**
  - **Published properties for UI binding:**
    - `previewImage: CGImage?` - The loaded image preview for display
    - `processedPreviewImage: CGImage?` - The processed image preview for display
    - `isProcessing: Bool` - Processing state
    - `logs: [LogEntry]` - Log entries for debugging
    - `performance: PerformanceMetrics` - Performance metrics
  - **Static utility methods:**
    - `RawrKit.createSecurityBookmark(for: URL) -> Data?` - Creates security-scoped bookmark for file persistence
  - **Instance methods:**
    - `loadRawFile(from: URL) async -> Bool` - (Legacy) Loads and processes RAW files with security-scoped access
    - `resolveBookmark(_: Data) -> URL?` - Resolves security-scoped bookmarks with logging
    - `invertImage() async -> Bool` - (Legacy) Applies film negative inversion processing
    - **`executeGraph(_: NodeGraph) async -> Bool`** - **PRIMARY API**: Executes the node graph and updates preview images
    - `clearGraphCache()` - Clears the graph execution cache (call when graph structure changes)
    - `clearSourceImageCache()` - Clears the source image cache (call when image URL changes)
    - `clearProcessedPreview()` - Clears the processed preview image (call when preview node is disconnected)
  - **DO NOT implement any of the following in the main app:**
    - Direct file access with `NSImage(contentsOf:)` or `Data(contentsOf:)`
    - Image processing or manipulation
    - Security-scoped resource handling
    - RAW file decoding
    - Node graph execution or processing logic
    - Any business logic
  - **Main app responsibilities:**
    - Display RawrKit's published images (previewImage, processedPreviewImage)
    - Call `rawrKit.executeGraph(nodeGraph)` when graph changes
    - Provide UI for node graph editing
    - Pass NodeGraph to RawrKit for processing
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

### Metal GPU Acceleration
All image processing operations use Metal compute shaders for GPU acceleration:
- **Shaders.metal**: Contains Metal compute kernels (invertImage, adjustExposure, applyGamma, copyTexture)
- Images are processed as Metal textures (rgba16Float format for high precision)
- Node processors execute Metal shaders through the command queue

### Source Image Caching
RawrKit implements source image caching to avoid redundant file loading:
- **Cache behavior**: When an image is loaded through `ImageInputProcessor`, it's cached in RawrKit
- **Cache lookup**: When `executeGraph()` needs the source image for the "Before" preview, it uses the cached version
- **Cache invalidation**: The cache is automatically cleared when the image URL changes (via `.task(id: imageInputNode?.imageURL)` in ContentView)
- **Benefits**: Reduces lag when connecting nodes by avoiding duplicate image loading and preview creation
- **Implementation**:
  - `ImageInputProcessor` calls `context.logger?.setCachedSourceImage()` after loading
  - `executeGraph()` calls `getCachedSourceImage()` to retrieve the cached image
  - UI calls `clearSourceImageCache()` when image URL changes

### Node System Architecture

The node system is fully implemented with a modular, extensible design:

#### Core Components (all in RawrKit):
1. **NodeProcessor.swift**: Protocol and base class for all node processors
   - `NodeProcessor` protocol: Defines `process()` and `canProcess()` methods
   - `MetalNodeProcessor`: Base class with Metal texture utilities
   - `ImageData`: Runtime representation of images flowing through the graph (contains MTLTexture + CGImage + metadata)
   - `ProcessingContext`: Shared Metal resources passed to all processors

2. **GraphExecutor.swift**: Graph execution engine with dependency resolution
   - Recursively executes nodes in dependency order
   - Caches outputs to avoid redundant processing
   - Handles connection traversal and data flow

3. **NodeProcessors.swift**: Concrete implementations of node processors
   - `ImageInputProcessor`: Loads images from disk with security-scoped access
   - `InversionProcessor`: Applies film negative inversion using Metal shader
   - `PreviewProcessor`: Terminal node that collects processed images
   - Each processor is self-contained and handles its own Metal shader execution

#### Adding New Nodes:
1. Add new case to `NodeType` enum in NodeTypes.swift
2. Create a new processor class in NodeProcessors.swift:
   ```swift
   public class MyNewProcessor: MetalNodeProcessor {
       public init() {
           super.init(nodeType: .myNew)
       }

       override public func process(inputs: [String: ImageData],
                                   node: NodeData,
                                   context: ProcessingContext) async -> [String: ImageData]? {
           // Implement processing logic using Metal
       }
   }
   ```
3. Add Metal shader to Shaders.metal if needed
4. Register processor in GraphExecutor.registerDefaultProcessors()

#### Data Flow:
1. UI calls `rawrKit.executeGraph(nodeGraph)`
2. GraphExecutor finds Preview nodes and traverses backward
3. Each node's processor is executed with inputs from upstream nodes
4. ImageData (Metal textures + CGImages) flows through connections
5. Results are cached to avoid re-execution
6. Final images are published to UI via `previewImage` and `processedPreviewImage`

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