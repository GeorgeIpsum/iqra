# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iqra is a native universal macOS/iOS/iPadOS ebook reader + library app
(Swift/SwiftUI), targeting rough feature parity with Apple Books. The
original Electron scaffold was abandoned; the project restarted 2026-07-11.

## Architecture

The validated architecture design lives at
`docs/superpowers/specs/2026-07-11-iqra-architecture-design.md` — read it
before making structural decisions. Key locked decisions:

- SwiftUI multiplatform app over three local Swift packages: IqraCore
  (shared models/protocols), IqraLibrary (GRDB catalogue + import
  pipeline), IqraReader (navigators: EPUB shipped via foliate-js in a
  WKWebView, vendored at pin `78914ae` under `Sources/IqraReader/Vendor/`;
  PDFKit for PDF and a native pager for CBZ/CBR still pending, M4)
- GRDB/SQLite persistence, records shaped for CloudKit (CKSyncEngine
  later); managed copy-on-import library folder; DRM-free formats only
- Adversarial design-review transcripts are in `.lil-bro/` (gitignored)

## Commands

- `swift test` — run all package tests (IqraCore, IqraLibrary, IqraReader); this is the primary gate
- `swift test --filter <TestClassName>` — run one test class
- `cd App && xcodegen generate` — regenerate the Xcode project (project.yml is the source of truth; iqra.xcodeproj is gitignored)
- `xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build` — build the app
