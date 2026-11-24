# Development

Run the commands below from the repository root. For installation and everyday use, see the [README](../README.md).

## Architecture and limits

Source editing is independent of the native renderer. Highlighting follows the website's token order, multiline strings and YAML frontmatter. Lines over its 2,000 UTF-16 code-unit limit are left uncolored. Indentation covers explicit blocks and branches while preserving hierarchy-based indentation in diagrams such as mindmaps. The syntax faces use Flexoki light and dark colors without setting a background fill.

```text
pele-mode.el + pele-font-lock.el       source editing and highlighting
                  pele.el             API, scheduler, cache, previews and Org
                     ↓
            src/pele-module.c         worker owns QuickJS and original Pele
                     ↓
              src/bridge.js           font measurements and portable SVG
                     ↓
                SVG result           Emacs image, file or Babel (ob-pele.el)
```

Only the Emacs thread calls the Emacs module API. A completion pipe wakes Emacs; a timer provides fallback delivery while requests are pending. Elisp submits at most eight jobs at once to the bounded native queue. Cancellation, deadlines and shutdown share this single request path. No polling runs when there is no pending work.

The JavaScript runtime has a 128 MiB memory limit. The bridge caps source at 50,000 characters, edges at 5,000 and upstream SVG at 4,000,000 characters. It resolves scoped CSS variables and corner radii for Emacs SVG display while preserving Pele's paths, labels and dimensions. Node fills and label backings remain intact. Diagram images and clickable links are disabled; external icon libraries and mathematical typesetters are not bundled, so Pele's text fallback applies.

## Verification

```sh
make check          # compile with warnings as errors; editor, integration and corpus tests
make test           # editor and renderer integration tests
make test-corpus    # all 522 documentation examples across 33 diagram types

# Verify the optional build without Pango:
make clean
make -j4 check PANGO_LIBS= PANGO_CFLAGS=
```

Run `make clean` before changing font backends, then rebuild normally to restore Pango. Linux CI checks both builds. Rendering tests use Emacs module assertions and cover cancellation, deadlines, queueing, recovery, cache behavior, preview cleanup, themes and Babel. The corpus checks the generated SVG as XML and compares type, dimensions, paths and text to the original engine using identical width estimates. It also exercises all examples with the default font backend.

The pure Elisp editor suite can run independently of the native build:

```sh
emacs -Q --batch -L . -L test -l pele-mode-tests -l pele-highlighting-tests -f ert-run-tests-batch-and-exit
```

Highlighting tests compare actual Emacs face ranges and edit sequences to reference output from the unmodified website highlighter, and verify its source hashes. To update references, use `node scripts/update-highlighting.mjs` (Node must provide `node:module.stripTypeScriptTypes`) and `node scripts/update-corpus.mjs` for rendering references. Node is only a development tool for regenerating these files.

Keep the vendored engines unmodified and pinned. Update the website source, Elisp port and highlighting reference together. Keep editing independent of rendering, and use the existing API and worker for integrations. Add regression tests for observable failures; avoid a second Mermaid parser or new abstractions without a concrete need.

For local timing, run `emacs -Q --batch -L . -l scripts/benchmark.el`. Results go to `test/output/performance.json` with normal GC settings. The measurements cover rendering, cache delivery, fontification and edits; GUI rasterization, redisplay, Emacs startup and the idle preview delay are excluded.

## Releases

Keep user-visible changes under `Unreleased` in [CHANGELOG.md](../CHANGELOG.md). When preparing a release, give that entry its version and date, and record any bundled Pele or QuickJS updates. Current dependency versions, source hashes and license notices belong in [vendor/README.md](../vendor/README.md).
