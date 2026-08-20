# Changelog

Notable changes to the `tikz` Quarto extension. Versions are the
`version:` field in `_extensions/tikz/_extension.yml`, which is what
`quarto add`/`quarto update` resolves.

## 1.6.1

Bug fixes and a refactor pass over the features added in 1.2–1.6; no new
options, and no change to what a correct document renders.

### Fixed

- **A no-op `%%| renderer: latex` produced a second cache entry.** The cache
  key was built by deleting keys from the same table the renderers read, so
  each option had to erase its own raw directive text before the key was
  taken. `renderer` did not, and any value resolving to the default — an
  explicit `latex`, or a value that had been rejected and warned about —
  re-keyed a byte-identical image. As in 1.5.0, that is invisible on a
  machine with TeX and fatal on a build host without one. The key is now
  built from the *resolved* values in a separate table.
- **The filter aborted on its first warning under plain `pandoc`.** Every
  `quarto.log` call assumed the Quarto global, so `pandoc --lua-filter` died
  while trying to report a mistake in the user's own document — despite the
  plain-pandoc fallbacks elsewhere in the file. Diagnostics now fall back to
  stderr.
- **Every render on Windows reported the TeX engine as missing.** The
  dependency probe shelled out to `command -v`, a POSIX shell builtin that
  does not exist under `cmd.exe`. It now searches `PATH` directly, honours
  `PATHEXT`, and is memoized instead of spawning a subprocess per diagram.
  The probe also no longer interpolates a metadata-controlled string into a
  shell command.
- **`svg-engine: dvisvgm` together with `svg-command` could not render.** The
  DVI request was keyed off `svg-engine` while the converter was chosen from
  `svg-command`, so the TeX run produced a DVI and the converter was handed
  an `{input}` naming a PDF nothing had written. Setting both now warns and
  says which one is ignored.
- **`latex-passthrough` hoisted a `\usetikzlibrary` out of a `tikzpicture`**
  when it was alone on its line — the one case the filter documents as
  off-limits, and the shape multi-line node content takes.
- **Unrecognized option values named the wrong fallback.** "falling back to
  'latex'" was printed even when the document-level setting was `tikzjax`,
  which is what actually applied.
- `{input}` / `{output}` substitution no longer misreads a `%` in a
  user-supplied `%%| filename:` as a capture reference.

### Changed

- `tests/run.sh` runs every suite, and CI runs it on each push and pull
  request. The suites need only `pandoc` — no TeX, no SVG converter.
- Internals split into testable pieces: `resolve_axes`, `convert_command`,
  `build_tex_document`, `as_figure`, `cache_path`, `preamble_parts`,
  `meta_string` / `meta_enum`. Test count went from 81 to 154.
- `example.qmd` now demonstrates `embed: inline` and `latex-passthrough`
  alongside the existing `renderer: tikzjax` example.

## 1.6.0

- **`embed: inline`** — emit the rendered SVG as markup rather than as an
  `<img src=…>` reference, so its labels are selectable, findable, reachable
  by page CSS, and visible to screen readers. HTML-family output only. This
  is what makes `svg-engine: dvisvgm` worth choosing, since its real `<text>`
  elements are unreachable through an `<img>`. Ids, CSS classes and
  `@font-face` families are namespaced per diagram, without which two
  diagrams on a page corrupt each other's glyphs and fonts. (#27)
- **One failing diagram no longer aborts the render.** A missing TeX engine
  used to hand `nil` to the cache writer, whose genuine runtime error took
  the whole document down. Failures are now reported by return value rather
  than `error()`, whose semantics inside a Quarto filter are not what they
  look like. (#30)

## 1.5.0

- **`latex-passthrough`** — under LaTeX output, hand the TikZ source to the
  host document instead of compiling it to an image, so the diagram is
  typeset by the same run as the surrounding text. `\usetikzlibrary` calls in
  the body are hoisted into the host preamble, because a library loaded
  inside a captioned block's `figure` environment is scoped to it while PGF
  records the load globally — breaking a later block. (#26)
- **Canonical cache key.** Keys are sorted and length-prefixed, so table
  iteration order cannot orphan every cached file at once, and two different
  option sets cannot hash alike. (#21)
- **Presentation metadata dropped from the code hash.** Adding a caption, or
  migrating from the deprecated `{.tikz filename=…}` fence attribute to
  `%%| filename:`, no longer re-keys an unchanged image. (#28)

  > Upgrading from 1.4.0 or earlier rekeys the cache once. If you commit an
  > in-tree `cache-dir`, do that first render on a machine with TeX.

## 1.4.0

- `%%|` directives take precedence over code-block fence attributes, and a
  key given both ways warns rather than being silently overridden.

## 1.3.0

- **`svg-command`** — escape hatch for wiring any PDF → SVG converter
  (`pdf2svg`, `mutool draw`, a script) without the filter having to bless
  each one. Takes precedence over `svg-engine`.

## 1.2.1

- Cache filenames include the diagram's basename, so a directory listing says
  which diagram in which document produced each entry. (#9)

## 1.2.0

- **`renderer: tikzjax`** — client-side rendering in the reader's browser via
  WebAssembly, needing no TeX distribution and no SVG converter. HTML output
  only; other formats drop the block with a warning. `tikzjax-url` points at
  a self-hosted copy or a fork.
- **`svg-engine`** — `inkscape` (default), `dvisvgm` or `pdftocairo`.
  `dvisvgm` consumes a DVI and embeds fonts as WOFF, keeping text selectable.
- **`tex-engine`** — `pdflatex` (default), `lualatex`, `xelatex`, ….
- **PDF passthrough** — under PDF output the intermediate PDF is embedded
  directly, skipping the SVG round-trip and preserving vector fidelity.
- **`tex-template`** — supply your own standalone template.

## 1.1.0

- `TEXINPUTS` is set so blocks can `\input` or `\usepackage` files sitting
  beside the `.qmd` or shipped with the extension. (#6)

## 1.0.0

- First stable release. `%%| key: value` directives become the canonical
  per-block syntax; fence attributes are deprecated. See the migration notes
  in the README.
