# Development

Run the commands below from the repository root. For installation and everyday use, see the [README](../README.md).

## Architecture and limits

Source editing is independent of the native renderer. The highlighter leaves lines over the website's 2,000 UTF-16 code-unit limit uncolored. Indentation covers explicit blocks and branches while preserving hierarchy-based indentation in diagrams such as mindmaps.

```text
pele-mode.el + pele-font-lock.el       source editing and highlighting
                  pele.el             API, scheduler, cache, previews and Org
             pele-markdown.el         Markdown block collectors and minor mode
                pele-module.el        verified, versioned module installation
                     ↓
            src/pele-module.c         worker owns QuickJS and original Pele
                     ↓
              src/bridge.js           font measurements and portable SVG
                     ↓
                SVG result           Emacs image, file or Babel (ob-pele.el)
```

Only the Emacs thread calls the Emacs module API. A completion pipe wakes Emacs; a timer provides fallback delivery while requests are pending. Elisp submits at most eight jobs at once to the bounded native queue. Cancellation, deadlines and shutdown share this single request path. No polling runs when there is no pending work.

Org and Markdown share one inline preview lifecycle: block collectors return `:begin`, `:end` and `:source` plists; the common layer owns overlays, idle refreshes and cancellation. The legacy Markdown collector scans fence boundaries and uses `markdown-mode` syntax properties to exclude comments and indented code; this also handles long backtick fences that older versions do not recognize. The Tree-sitter collector uses the existing `markdown-ts-mode` Markdown tree. Neither creates a Mermaid parser or adds a Tree-sitter requirement to other modes.

The preview loop encodes its settings key and measures the window once for all blocks. Cached image displays are reused until their image, fitted size or virtual cursor changes. Org collection parses elements only, preserving nested source blocks while skipping paragraph objects. Org result positions are keyed by the buffer's text modification counter and Babel results keyword; text edits invalidate them, while image refreshes and theme changes reuse them.

The JavaScript runtime has a 128 MiB memory limit. The bridge caps source at 50,000 characters, edges at 5,000 and upstream SVG at 4,000,000 characters. It resolves scoped CSS variables and corner radii for Emacs SVG display while preserving Pele's paths, labels and dimensions.

## Verification

```sh
make check          # compile with warnings as errors; editor, integration and corpus tests
make test           # editor and renderer integration tests
make test-lisp      # editor, website highlighting and installer; no native build
make test-renderer  # renderer, Org/Babel and Markdown integration tests
make test-corpus    # all 522 documentation examples across 33 diagram types

# Verify the optional build using width estimates only:
make clean
make -j4 test-renderer TEXT_BACKEND=estimate
```

Run `make clean` before changing font backends, then rebuild normally to restore native font measurements. `TEXT_BACKEND=auto` selects Core Text on macOS, Pango on Linux when available, and otherwise estimates. Explicit `coretext`, `pango` and `estimate` values are also supported. Linux CI runs `make check` with native font measurements, then the integration suite with an estimate-only build. Rendering tests use Emacs module assertions and cover cancellation, deadlines, queueing, recovery, cache behavior, preview cleanup, themes and Babel. Each corpus case compares type, dimensions, paths and text to the original engine using identical width estimates, then checks SVG XML with the default font backend. This covers both measurement paths without repeating the whole corpus for the estimate-only build.

Markdown tests exercise both real major modes when available, including nested literal fences, edits, indentation, unclosed fences and lifecycle cleanup. Tests for an unavailable host mode or Markdown grammar are skipped. Debian/Ubuntu's `elpa-markdown-mode` is discovered automatically for tests. For a local checkout, pass `make check MARKDOWN_MODE_DIR=/path/to/markdown-mode`; `markdown-ts-mode` tests use the Markdown grammars already installed for that mode.

Highlighting tests compare actual Emacs face ranges and edit sequences to reference output from the unmodified website highlighter, and verify its source hashes. To update references, use `node scripts/update-highlighting.mjs` (Node must provide `node:module.stripTypeScriptTypes`) and `node scripts/update-corpus.mjs` for rendering references. Node is only a development tool for regenerating these files.

For an optional GUI rasterization check, run `emacs -Q -L . -l test/pele-gui-test.el`. It opens the Org gallery in a separate Emacs and writes actual image dimensions and errors to `test/output/gui-results.json`.

Run the inline interaction regressions in a separate graphical Emacs with `emacs -Q -L . -L test -l pele-inline-tests --eval '(ert-run-tests-interactively "pele-inline-")'`. They cover EOF navigation with and without a final newline, normal editing and undo, width/height fitting, window resizing, wheel termination, the native image viewer and Org result-image deduplication. Add the Markdown mode directory to `load-path` to include its keyboard checks.

Optional modal tests use real Meow and Evil from `load-path`, including their command hooks, selections, counts, operators and rebound keys. Motion advice handles only single-step user commands in preview buffers. A dynamic guard prevents a modal command and its nested native motion from handling the same preview twice. Layout notifications preserve focus; source edits dismiss it. Evil's cursor adjustment skips virtual preview positions, and the full-size image buffer uses Emacs state. Unloading Pele removes its motion advice.

Keep the vendored engines unmodified and pinned. Update the website source, Elisp port and highlighting reference together. Keep editing independent of rendering, and use the existing API and worker for integrations. Add regression tests for observable failures; avoid a second Mermaid parser or new abstractions without a concrete need.

For local timing, run `emacs -Q --batch -L . -l scripts/pele-benchmark.el`. Results go to `test/output/performance.json` with normal GC settings. The measurements cover rendering, cache delivery, fontification and edits; GUI rasterization, redisplay, Emacs startup and the idle preview delay are excluded.

## Releases

The `Native packages` workflow builds and verifies macOS and Linux bundles for Apple Silicon/ARM64 and x86-64. It uploads workflow artifacts for release preparation. Before tagging a release, wait for both `Tests` and `Native packages` to pass on the exact commit. Download that run's artifacts and publish all binary/source archives and checksum files under `v<pele-version>`. Keep all Elisp version headers equal to `pele-version`. The Lisp files form one package; their `Package-Requires` headers must list external dependencies, never `pele` itself.

`pele-module.el` verifies the archive checksum and every manifest file, along with the exact Elisp version, platform and module ABI. Installation moves a verified staging directory into the module cache; failure preserves the old copy. See the README for download policies and user commands.

On macOS, `make package` produces a stripped, ad-hoc signed archive in `dist/`, together with a SHA-256 file. Release builds target macOS 12+ using `MACOSX_DEPLOYMENT_TARGET=12.0`; they link only to system Core Text, Core Foundation and libSystem. The packager rejects Homebrew library dependencies. The workflow runs Lisp tests before packaging and renderer/corpus tests against the extracted bundle, so each suite runs once.

For Linux, run:

```sh
docker build -f scripts/linux-package.Dockerfile --output type=local,dest=dist .
```

The builder uses Ubuntu 22.04 (glibc 2.35) with an Emacs 29 module header. It bundles the complete Pango dependency closure in `lib/`, except glibc itself. Relative library search paths keep the archive relocatable; neither an absolute build path nor `LD_LIBRARY_PATH` is needed. Libraries remain dynamically linked and replaceable. Installed system fonts are used. When the system has no Fontconfig configuration, a private fallback searches standard system and user font directories without changing Emacs's font settings.

The package script records library versions and hashes, copies copyright and license notices, and downloads the exact Debian/Ubuntu dependency sources into a companion `*-sources.tar.gz`. Publish that source archive and both checksum files alongside each Linux binary archive. Direct `make package` on Linux therefore requires `patchelf`, binutils, Python and matching `deb-src` repositories; use the container for release builds. Dependencies are fetched only while preparing a release, never at runtime.

The Linux verification stage extracts the archive into a new location on Ubuntu 24.04, with no installed Pango or compiler and no `/etc/fonts`. It runs renderer and corpus tests against the extracted module and refuses estimated-width fallback. The workflow also tests the bundle with an SVG-capable Emacs for preview checks; tests requiring an unavailable SVG backend or Markdown mode are skipped. The macOS job verifies the extracted signed module with the same tests. Each binary archive contains its module, dependency directory (Linux), licenses and `manifest.json`. Users must keep these together when extracting alongside `pele.el`; no font files are included. These bundles target macOS and glibc Linux, not Windows or musl/Alpine.

Keep user-visible changes under `Unreleased` in [CHANGELOG.md](../CHANGELOG.md). When preparing a release, give that entry its version and date, and record any bundled [Pele](https://github.com/obsidianmd/pele) or [QuickJS](https://github.com/bellard/quickjs) updates. Current dependency versions, source hashes and license notices belong in [vendor/README.md](../vendor/README.md).
