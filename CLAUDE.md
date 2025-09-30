# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rawr is a macOS document-based SwiftUI application that is a node based RAW file editor. It targets both digital and film photographer and seeks to help them automate parts of their photo editting workflow.

## Architecture

### Core Components

- **RawrApp.swift**: Main app entry point using DocumentGroup pattern with minimum window size constraints (900x700)
- **RawrDocument.swift**: Document model conforming to FileDocument protocol, handles custom `.flow` file type (`xyz.runkaizhang.flow`)
- **ContentView.swift**: Main view (currently minimal with just a Spacer)
- **RawrKit/**: Framework/library directory for image processing logic
  - **IMPORTANT**: RawrKit handles security-scoped resource access internally in `loadRawFile()` (line 109 in Source.swift)
  - All image processing and file I/O operations should be encapsulated in RawrKit
  - DO NOT directly load images with NSImage/CGImage in main app - use RawrKit methods instead
  - Main app should only handle UI and pass URLs to RawrKit for processing

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
- "Always update the Claude.MD when new functionality is added to Rawrkit"