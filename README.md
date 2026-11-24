# pele.el

Edit Mermaid and render SVG diagrams in Emacs with the original [Pele](https://github.com/obsidianmd/pele) engine maintained by kepano / Obsidian.

- Pure Elisp editing mode with the official website's highlighting rules.
- Standalone previews, live Org previews, SVG export and Org Babel support.
- A native worker embeds QuickJS and the unmodified Pele bundle. No Mermaid CLI, Node.js, browser, network access or rendering subprocess is required at runtime.

Pele 1.13.0 and QuickJS 2026-06-04 are vendored. All 33 built-in diagram types are available, including flowcharts, sequence, class, ER, state, Gantt, Git graphs, pie, mindmap, Sankey, radar and treemap. Compatibility and layout follow **Pele**, including its differences from Mermaid.js. This package is currently built from source; prebuilt releases and Windows support are not provided.

## Build and install

Requirements:

- Emacs 29.1+ with dynamic module support; SVG image support for previews.
- macOS or Linux, a C compiler with pthreads, Make, Python 3.10+ and `emacs-module.h` from your Emacs installation.
- Recommended: `pkg-config` and Pango 1.44+ development files (`pangocairo`) for accurate font measurements. Without Pango, the renderer uses Pele's built-in width estimates.

Install the optional font backend with `brew install pkg-config pango` on Homebrew, or `apt install pkg-config libpango1.0-dev` on Debian/Ubuntu. Then:

```sh
git clone https://github.com/LuciusChen/pele.el.git ~/repos/pele.el
cd ~/repos/pele.el
make -j4
make check
```

If Emacs or its header is elsewhere, use `make EMACS=/path/to/emacs EMACS_INCLUDE=/path/to/include`. Keep the resulting `pele-native.dylib` (macOS) or `pele-native.so` (Linux) alongside `pele.el`.

Add to your Emacs configuration:

```elisp
(add-to-list 'load-path (expand-file-name "~/repos/pele.el"))
(require 'pele)
(add-hook 'org-mode-hook #'pele-org-mode)
```

For editing and highlighting alone, require `pele-mode` instead. It needs no native build, Mermaid CLI, Tree-sitter or grammar library. Loading the Lisp files does not load the native renderer until the first render.

## Use

Open a `.mmd` or `.mermaid` file to enter `pele-mode`. Use `C-c C-p` to preview or `C-c C-e` to export SVG. `M-x pele-preview` and `M-x pele-export` also work on an active region in any buffer, the Org source block at point, or a whole diagram buffer. In a preview, `g` renders again, `s` saves SVG and `q` quits.

In Org, `pele-org-mode` shows previews below both `mermaid` and `pele` blocks:

```org
#+begin_src mermaid
flowchart LR
  Edit --> Preview --> Export
#+end_src
```

Previews are overlays and do not modify the file. Edits refresh after 0.2 idle seconds by default. Incomplete input keeps the last successful image; the preview's help text reports the error. Try [examples/gallery.org](examples/gallery.org) and [examples/editor.org](examples/editor.org).

Both Org block languages use `pele-mode` for native source highlighting and `C-c '` editing, unless you have explicitly chosen another source mode. Keep `org-src-fontify-natively` enabled. The highlighter ports the official website's lexical rules, including multiline strings and YAML frontmatter; it does not validate Mermaid syntax. Rendering reports syntax errors and source locations when Pele provides them. Lines over the website's 2,000 UTF-16 code-unit limit are left uncolored, just as on the website.

Indentation covers explicit blocks and branches. Hierarchy-based diagrams such as mindmaps keep their existing indentation. Customize `pele-indent-offset` (default 2) and the `pele-highlighting` face group as needed. The syntax colors follow the website's Flexoki palette, with light and dark variants and no background fill.

### Org Babel

```elisp
(require 'ob-pele)
```

```org
#+begin_src pele :file diagram.svg :results file graphics
sequenceDiagram
  Alice->>Bob: Hello
  Bob-->>Alice: Hi
#+end_src
```

`:file` is required and must end in `.svg`. Optional `:width` and `:font-size` use pixels. Org's normal Babel execution and confirmation settings apply.

To handle existing `mermaid` Babel blocks, call `(pele-babel-enable-mermaid)` explicitly. If using `ob-mermaid`, load it first. `(pele-babel-disable-mermaid)` restores the execution function saved when the override was enabled. Requiring `ob-pele` alone leaves other Babel backends in place.

## Appearance and render options

```elisp
(setq pele-theme 'auto
      pele-background 'transparent
      pele-text-measurement 'native)
```

The default transparent canvas lets the Emacs buffer show through; boxes, circles and other nodes retain their fills. Set `pele-background` to `theme` for a solid canvas, for example when exporting onto a different background.

`pele-theme` accepts `auto` (Emacs foreground/background plus Pele's palette), `pele` (the full official light/dark palette), `light`, `dark`, or an alist of CSS variables such as `(("--pele-bg" . "#202124") ("--pele-fg" . "#eeeeee"))`.

Other user options include `pele-font-size`, `pele-font-family`, `pele-font-family-mono`, `pele-preview-delay`, `pele-render-timeout`, `pele-cache-size` and `pele-cache-byte-limit`. Font measurements use Pango when available, including bold, italic and monospace labels. Browser and Emacs SVG display can still differ slightly.

## Lisp API

```elisp
(pele-render "flowchart LR\nA --> B" '(:theme dark :max-width 800))
;; => (:ok t :svg "<svg ...>" :width ... :height ... :type "flowchart" ...)

(let ((id (pele-render-async
           "flowchart LR\nA --> B"
           (lambda (result)
             (if (plist-get result :ok)
                 (message "Rendered %s" (plist-get result :type))
               (message "%s" (plist-get (plist-get result :error) :message)))))))
  ;; Retain ID; call (pele-cancel id) when the result is no longer needed.
  id)
```

Async callbacks run later on the Emacs thread, including cache hits. Cancellation suppresses the callback. `pele-render` waits and signals `pele-error` on failure, carrying a message and error plist. Interactive previews use the async API.

Both functions accept an options plist:

| Options | Meaning |
| --- | --- |
| `:font-size`, `:font-family`, `:font-family-mono` | Label size in pixels and font families |
| `:measure-text` | `native` (Pango if built in) or `estimate` (upstream width table) |
| `:theme`, `:background` | Same values as the corresponding user options |
| `:max-width`, `:auto-direction` | Width constraint; opt in to choosing direction instead of preserving the source direction |
| `:timeout` | Render deadline in milliseconds, from 1 to 60,000; default 1,000 |
| `:now` | Epoch milliseconds for deterministic Gantt output |
| `:config` | JSON-compatible alist or hash table of Mermaid configuration defaults |

Configuration in the diagram source takes precedence over `:config`. Gantt results using the current date are not cached; supply a numeric `:now` to cache them. Successful results otherwise use an LRU cache bounded by 32 diagrams and 16 MiB of SVG data by default.

`M-x pele-clear-cache` discards cached results. `M-x pele-shutdown` cancels pending requests and releases the worker; the next render starts it again. Call it before reloading edited Lisp files. **Restart Emacs after rebuilding a loaded native module**: loading Lisp again cannot replace the native binary.

## Architecture and limits

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

## Development and verification

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

## License

Project code is licensed under the [MIT License](LICENSE). Pele, QuickJS, the website highlighter and the documentation examples retain their upstream MIT licenses and copyright notices. Preserve those notices when redistributing sources or bundled modules. See [vendor/README.md](vendor/README.md) and [test/corpus/SOURCE.md](test/corpus/SOURCE.md) for versions, hashes and attribution.
