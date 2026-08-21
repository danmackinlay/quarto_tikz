# Changelog

Notable changes to the `tikz` Quarto extension. Versions are the
`version:` field in `_extensions/tikz/_extension.yml`, which is what
`quarto add`/`quarto update` resolves.

## 1.7.0

One option removed, one `%%|` parser where there were three, and a round of
fixes to inline SVG embedding. No new options.

### Fixed

- **`%%| fig-attr:` is gone. It could only ever abort the render.** The nested
  block was parsed with `pandoc.read(value, 'yaml')`, and `yaml` is not one of
  pandoc's input formats, so reaching that call raised "Unknown input format
  'yaml'". It did so from inside option parsing, upstream of the guard added in
  1.6.0 that keeps one bad diagram from taking the document down, so the whole
  render died with it. Whether it was reached at all turned on the old key
  pattern, which required a literal ": " — colon *space*: `%%| fig-attr:` on its
  own never matched and was silently ignored, while the same line with one
  trailing space, or with anything after the colon, aborted the build. A feature
  that has never worked in any form cannot be depended on, so it is removed
  rather than repaired; the README already pointed anything needing a
  cross-reference at the fenced-div pattern, which is where it stays. Figure
  attributes set the other ways — `%%| label:`, `%%| name:`, and `fig-`-prefixed
  fence attributes — are unaffected.
- **`format: pdf` with `svg-engine: dvisvgm` failed every diagram.** Under
  LaTeX output the TeX run's own PDF is embedded directly and no converter
  runs, but the DVI request was still keyed off `svg-engine` — so the TeX
  engine was asked for a DVI and the filter then read a PDF nothing had
  written. `svg-engine` correctly has no effect under LaTeX output now.
- **Two diagrams could share one image file.** Only the cache folded a
  block's options into the filename it wrote; the mediabag entry and the
  `save-tex` directory used the code hash alone. Two blocks with identical
  TikZ and different options — or sharing an explicit `%%| filename:` —
  therefore collapsed onto one file, and the block rendered first displayed
  the other one's diagram. All three now share one name, derived from the
  code and the options together.
- **`embed: inline` mis-namespaced some stylesheets.** A grouped CSS selector
  (`.f0, .f1 {`) was skipped while the `class=` attributes it applied to were
  still renamed, silently detaching the style; an element carrying more than
  one class (`class="f0 bold"`) was not namespaced at all, so two diagrams on
  a page could still collide through it. A `<svg …/>` with no content put its
  `<title>` outside the element, and an attribute value containing `>` had the
  `<title>` spliced into the middle of it.
- **`svg-command` accepted a command it could not run.** Only emptiness was
  checked, so a single-word `svg-command: pdf2svg` was accepted and then run
  with no PDF to read and nowhere to write. It must now name both `{input}`
  and `{output}`.
- **A relative `tex-template:` path could fail to resolve.** Paths were made
  absolute against `$PWD`, which is a shell convention rather than something
  every launcher exports; the fallback when it was missing produced exactly
  the relative path that resolution exists to prevent.
- **A directive on the block's last line was silently ignored.** Pandoc strips
  the trailing newline from a code block, and the option reader's pattern ran to
  a newline, so a `%%| caption:` or `%%| renderer:` written as the block's final
  line set nothing at all.
- **A trailing space made a valid value unknown.** `%%| renderer: latex ` carried
  its space into the enum lookup, was rejected, and warned about a renderer the
  user had spelled correctly. Values are trimmed now.
- **An empty value consistently means "unset".** Whether `%%| header-includes:`
  recorded an empty string or nothing at all previously turned on invisible
  trailing whitespace.
- `%%| key:value` with no space after the colon now parses; the old pattern
  required a literal ": ".
- Under `latex-passthrough`, a directive sharing its line with code is no longer
  emitted verbatim into the shipped `.tex`.
- **`embed: inline` could lose a diagram's font, and could corrupt its own
  labels.** Three faults, all from rewriting names by pattern across the whole
  document rather than by where a name can legally appear. A `@font-face`
  family was renamed while a reference to it in `style="font-family:…"` was
  not — there the closing quote ends the declaration, and only a `;` or `}`
  was recognised — so the text asked for a family that no longer existed and
  silently fell back. An `@font-face` rule declaring `font-family` after `src`
  was not recognised at all, so its family was never namespaced and two
  diagrams could still collide through it. And a class name occurring in a
  diagram's *own label text* — `.f0` inside `version .f0 released` — was
  rewritten as though it were a selector, corrupting the rendered text.
  Rewriting is now scoped to CSS text (a `<style>` body or a `style="…"`
  value) and to named attributes, and nothing else is touched; quoted family
  names are handled as well.
- A `.tex` file that could not be written now says so, rather than surfacing
  one step later as a LaTeX error about a file that was never there.

- **A quoted boolean meant different things at different levels.** Options
  were read five different ways depending on where they were written, so
  `cache: "true"` was compared with `== true` and silently ignored, while
  `save-tex: "false"` was compared for Lua truthiness — where a non-empty
  string is true — and silently switched `save-tex` *on*. Only
  `latex-passthrough` parsed its value properly. All options now read
  `true`/`false`, `yes`/`no` and `1`/`0` alike, quoted or not, and anything
  else warns instead of being guessed at.
- **`%%| additional-packages:` was not an option.** The kebab-case spelling —
  the natural one, in a vocabulary that is otherwise entirely kebab-case —
  fell through to the image-attribute catch-all and became
  `<img additional-packages="\usepackage{…}">`. Both it and
  `additionalPackages` are accepted now.
- Diagnostics that list an option's permitted values take them from the
  option's own declaration, so a message can no longer disagree with the set
  it describes.

### Changed

- Every option is declared once — type, default, scope, permitted values —
  and read through a single reader, replacing five mechanisms that each
  applied to a different subset. Each of the three fixes above is a
  consequence of that rather than a patch on top of it.
- **An unrecognised `%%|` directive now warns.** It is still passed through as
  an image attribute, so nothing that worked stops working, but a typo
  (`%%| capton:`) says so instead of appearing in the output as
  `<img capton="…">`. A directive naming a document-level option — `%%| cache:
  true` — is reported and ignored, since it never had an effect there. Fence
  attributes are unaffected: an arbitrary image attribute is what they are for.
- Generated image filenames change shape, from a bare 40-character SHA1 to
  the `<label>.<short-hash>.<ext>` form the cache has used since 1.2.1 — so
  `my-fancy-diagram.53efa4b1.svg` rather than `8cd4809a63b4….svg`. This is
  what fixes the collision above; it also means a mediabag or `save-tex`
  listing says which diagram produced each file, as a cache listing already
  did.
- The three `%%|` parsers are now one. The option reader, the cache-key code
  stripper and the passthrough body preparer each carried their own idea of what
  a `%%|` line was, and they disagreed — which is what every parsing fix above
  comes down to. A single pass now answers both questions the filter asks of a
  block: what the user set, and what code is left once the directives are gone.

  > Upgrading rekeys the cache once for any block whose directive values carry
  > trailing whitespace, or which relied on the old empty-value behaviour. If
  > you commit an in-tree `cache-dir`, do that first render on a machine with
  > TeX.

- Inlined SVGs are namespaced in one pass per rewrite rather than one per
  name, which also removed the pattern-escaping the old approach needed:
  22.0 ms to 3.7 ms on a 69 KB `pdftocairo` SVG.
- The test suites share one assertion helper (`tests/harness.lua`) instead of
  each carrying its own copy, and two new suites cover the directive parser,
  the option router and the document-level configuration. 154 checks to 302,
  the latest of them pinning the inline-SVG scoping rules above and the
  option-precedence chain.
- A diagram's artifact name is derived once per render instead of three times.
  The cache lookup, the cache write and the mediabag entry each recomputed it
  from the same `(basename, code, options)` triple — a canonical encoding and
  a SHA1 apiece; they now take the name already in hand.
- One idea of what a loader call is. `latex-passthrough`'s move pass and its
  copy pass each carried their own matcher, which disagreed about whitespace
  between a macro and its argument; the move pass is now expressed in terms of
  the scanner the copy pass uses.
- Source comments no longer retell incidents the CHANGELOG already records;
  what remains is the reasoning a maintainer would otherwise have to
  rediscover.
- The README is a third shorter (961 lines to 777). The "Known bugs" section
  is gone — it restated "Captions and cross-references" in full — the 1.0.0
  upgrade guide is a table rather than 96 lines of prose, and the explanations
  that appeared in two or three places each now appear once. Two stale spots
  went with it: the only image in the file was a broken link, and the upgrade
  example still set `%%| format: svg`, an option that has not existed for
  several releases and now warns.
- `example.qmd` explains what each block demonstrates and leaves the reasoning
  to the README, rather than repeating it.
- `example.qmd` no longer sets `save-tex` and `tex-dir`, so rendering it leaves
  no `tikz-tex/` directory behind for anyone who copies its front-matter.

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
