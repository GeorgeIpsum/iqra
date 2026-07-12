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
  pipeline), IqraReader (navigators: foliate-js-in-WKWebView for
  EPUB/MOBI, PDFKit for PDF, native pager for CBZ/CBR)
- GRDB/SQLite persistence, records shaped for CloudKit (CKSyncEngine
  later); managed copy-on-import library folder; DRM-free formats only
- Adversarial design-review transcripts are in `.lil-bro/` (gitignored)

## Commands

No build system exists yet (pre-scaffold). Update this section when the
Xcode project / SPM packages land.
