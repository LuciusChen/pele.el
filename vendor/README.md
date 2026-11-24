# Vendored dependencies

Runtime builds and execution do not fetch dependencies.

| Dependency | Version | Source archive | SHA-256 |
|---|---|---|---|
| [Pele](https://github.com/obsidianmd/pele) | 1.13.0 | https://registry.npmjs.org/pele/-/pele-1.13.0.tgz | `00f879d86c5a6ece897ef70e18fd228a9952bba338a0cb1293b373900d7414bd` |
| [QuickJS](https://github.com/bellard/quickjs) | 2026-06-04 | https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz | `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a` |

`pele/pele.global.js`, `pele/package.json` and `pele/LICENSE` are copied without modification from the npm archive. [Pele](https://github.com/obsidianmd/pele) is developed by [kepano](https://github.com/kepano) at [Obsidian](https://obsidian.md). Documentation and a playground are at [pele.run](https://pele.run).

The Flexoki color values and 6px corner radius in `pele.el` are from the upstream website's `website/src/styles/pele-theme.scss` and `base.scss` at commit `3a2f075ee0c3d914f0fad3545fc0f193693975ac`, under the same MIT license retained in `pele/LICENSE`.

`pele-website/highlight.ts` and `pele-website/playground-limits.ts` are unmodified copies from `website/src/lib/` at that same commit. Their original MIT license is retained in `pele-website/LICENSE`. They are development references only. `pele-font-lock.el` ports the Mermaid rules to Elisp; its syntax face colors come from the website's `base.scss` / `code.scss` (dark) and the corresponding Flexoki light palette. The fontification adapter, line cache and basic indentation are Emacs-specific. `scripts/update-highlighting.mjs` runs the original website code to generate `test/corpus/highlighting.json`, which records the source hashes and expected token classes / ranges.

`quickjs/` contains the unmodified runtime C sources, supporting headers, VERSION and LICENSE from the official archive. It omits the command-line programs, libc bindings, examples and tests; no OS or filesystem JavaScript bindings are exposed by the host. [QuickJS](https://github.com/bellard/quickjs) is by Fabrice Bellard and Charlie Gordon. Documentation and source releases are at [bellard.org/quickjs](https://bellard.org/quickjs/).

Project code and the vendored dependencies are MIT licensed. The project's license is in [../LICENSE](../LICENSE). Retain each upstream license and copyright notice when distributing the sources or a bundled native module: [pele/LICENSE](pele/LICENSE), [quickjs/LICENSE](quickjs/LICENSE) and [pele-website/LICENSE](pele-website/LICENSE). The documentation examples have their own provenance and retained license in [../test/corpus/SOURCE.md](../test/corpus/SOURCE.md).

Linux release bundles additionally copy the build distribution's Pango font libraries and their transitive dependencies, excluding glibc. These are not vendored here or covered by the project's MIT license. Each bundle records exact package/source versions and file hashes in `manifest.json`, includes notices in `licenses/`, and has a companion archive containing the corresponding source packages. Keep those archives and notices with published downloads. See [../docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md) for the packaging workflow. macOS bundles use system frameworks and carry no additional font libraries.
