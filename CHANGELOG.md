# Changelog

## Unreleased

- Fit previews to both window dimensions and support keyboard focus, with `RET` opening the original-size diagram in Emacs's image viewer.
- Share preview navigation between native Emacs, Meow and Evil movement commands while preserving counts, selections and operators.
- Stop mouse-wheel retries when an inline preview at the end of a buffer cannot scroll further.
- Keep Org previews before following blank lines so typing beneath a diagram stays below it.
- Suppress duplicate Org Babel result images while live previews are enabled, retaining result links and files and restoring Org's image display on disable.
- Reduce inline refresh allocations by sharing render settings and window dimensions, reusing unchanged displays and retaining Org result positions until the text changes.
- Simplify Org block extraction and HTTP download handling.
- Remove redundant highlighting checks and unused reference data; split test targets to avoid repeated CI suites.
- Consolidate preview and development documentation.

## 0.0.1 — 2026-11-24

First public release.

### Added

- Mermaid source editing with the official Pele website's highlighting rules in pure Elisp.
- Local SVG rendering with the original Pele engine embedded in a native worker.
- Standalone previews, live previews for Org `mermaid` and `pele` blocks, and SVG export.
- Live Mermaid fenced code block previews with `pele-markdown-mode`, supporting `markdown-mode`, `gfm-mode` and `markdown-ts-mode`.
- Org Babel support, with an optional override for existing Mermaid blocks.
- Emacs-aware themes, transparent diagram canvases and native font measurements.
- System Core Text font measurements on macOS, without additional font libraries.
- Relocatable native bundles, with Linux font libraries, dependency sources, license notices and checksums; a four-platform workflow verifies archives before upload.
- `pele-download-module`, with exact-version downloads, archive and file verification, a persistent module directory, and an optional first-use download prompt.
- Synchronous and asynchronous Lisp APIs with cancellation, render caching and deadlines.

### Bundled engines

- [Pele](https://github.com/obsidianmd/pele) 1.13.0 and [QuickJS](https://github.com/bellard/quickjs) 2026-06-04. Source archives, hashes and license notices are recorded in [vendor/README.md](vendor/README.md).
