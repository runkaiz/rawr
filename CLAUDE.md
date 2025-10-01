# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

Rawr is a macOS SwiftUI node-based RAW file editor for digital and film photographers to automate photo editing workflows.

## Architecture

### Core Principle: RawrKit = Backend, Rawr = UI

**CRITICAL**: All business logic goes in RawrKit. The Rawr app is purely a UI layer.

### Core Components

- **RawrKit/** (in `Rawr/RawrKit/`): All business logic
  - Security-scoped resource access, file I/O, RAW decoding
  - Node graph execution with Metal GPU acceleration
  - Image processing and computational operations

- **Main App**: UI only
  - `RawrApp.swift`: DocumentGroup entry point (min window: 900x700)
  - `RawrDocument.swift`: FileDocument for `.flow` files
  - `ContentView.swift`: UI presentation and interaction
  - `NodeGraphView.swift`, `NodeView.swift`: Node editor UI

### RawrKit API

**Published properties:**
- `previewImage: CGImage?` - Before image
- `processedPreviewImage: CGImage?` - After image
- `isProcessing: Bool`, `logs: [LogEntry]`, `performance: PerformanceMetrics`

**Key methods:**
- `executeGraph(_: NodeGraph) async -> Bool` - PRIMARY API for graph execution
- `createSecurityBookmark(for: URL) -> Data?` - Static bookmark creator
- `resolveBookmark(_: Data) -> URL?` - Bookmark resolver
- `clearGraphCache()`, `clearSourceImageCache()`, `clearProcessedPreview()` - Cache management

**Main app must NOT:**
- Directly access files (`NSImage(contentsOf:)`, `Data(contentsOf:)`)
- Process images or handle security-scoped resources
- Implement any business logic

## Configuration

- **Bundle ID**: `xyz.runkaizhang.Rawr`
- **Document Type**: `.flow` files (`xyz.runkaizhang.flow`)
- **Deployment Target**: macOS 15.4
- **Testing**: Swift Testing framework

## Development

**Build command:**
```bash
xcodebuild -scheme Rawr -configuration Debug build
```
Always build after code changes to verify compilation.

## Metal GPU Acceleration

All image processing uses Metal compute shaders (rgba16Float textures). Shaders in `RawrKit/Shaders/`:
- `InversionShader.metal`, `ExposureShader.metal`, `GammaShader.metal`, `DenoiseShader.metal`, `CombinationShader.metal`

**Source image caching**: `ImageInputProcessor` caches loaded images; `executeGraph()` reuses cached images for "Before" preview. Cache clears when image URL changes.

## Node System Architecture

**Core components (all in RawrKit):**

1. **NodeProcessor.swift**: Base protocol and classes
   - `NodeProcessor` protocol, `MetalNodeProcessor` base class
   - `ImageData`: Runtime image representation (MTLTexture + CGImage + metadata)
   - `ProcessingContext`: Shared Metal resources

2. **GraphExecutor.swift**: Execution engine
   - Dependency resolution, caching, connection traversal

3. **Nodes/**: Processor implementations
   - `ImageInputProcessor`, `InversionProcessor`, `ExposureProcessor`, `GammaProcessor`, `DenoiseProcessor`, `CombinationProcessor`, `PreviewProcessor`
   - Each handles its own Metal shader execution

### Adding New Nodes

1. **NodeTypes.swift**: Add case to `NodeType` enum, icon, maxAllowedCount, inputs/outputs in `init()`, parameters, migration logic in `init(from:)`
2. **Nodes/MyNewProcessor.swift**: Create processor class extending `MetalNodeProcessor`, load shader in `init()`, implement `process()`
3. **Shaders/MyNewShader.metal**: Create Metal kernel function
4. **GraphExecutor.defaultProcessors()**: Register processor
5. **NodeUIFactory.registerDefaultDescriptors()**: Add UI descriptor with `SliderComponent`, `ImagePickerComponent`, or empty descriptor

**Data flow**: UI calls `executeGraph()` → GraphExecutor traverses from Preview nodes backward → Processors execute with cached results → Images published to UI

## Implementation Guidelines

- **RawrKit first**: File ops, image processing, computation, state management, security-scoped resources go in RawrKit
- **UI pattern**: `@StateObject var rawrKit = RawrKit()` → call `executeGraph()` → bind to published properties
- **Update CLAUDE.md** when adding RawrKit functionality