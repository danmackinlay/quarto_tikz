# TikZ Extension For Quarto

Render [PGF/TikZ](https://en.wikipedia.org/wiki/PGF/TikZ) diagrams in [Quarto](https://quarto.org/).

## Installing

```bash
quarto add danmackinlay/quarto_tikz
```

This installs the extension under `_extensions`. If you're using version
control, check that directory in.

Upgrading a document written against the pre-1.0 block syntax? See
[CHANGELOG.md](CHANGELOG.md) — 1.0.0 is the release that changed it.

## Dependencies

You need a TeX distribution (TeX Live or MacTeX) on your `PATH`.
`pdflatex` is invoked by default; set `tikz.tex-engine` for `lualatex`
or `xelatex` (e.g. for `fontspec` / complex Unicode scripts).

For HTML and other non-PDF outputs you also need a PDF/DVI → SVG
converter — by default `inkscape` (≥ 1.0), overridable via
`tikz.svg-engine`. Rendering only to PDF needs no converter at all: the
intermediate PDF is embedded directly. See the
[configuration reference](#configuration-reference) for both, and the
[Inkscape-free CI recipe](#inkscape-free-ci-tinytex-on-github-actions-etc)
for minimal CI images.

Under `renderer: tikzjax` (HTML output only) none of the above is
required: rendering happens in the reader's browser via WebAssembly.
See [Renderers](#renderers).


## Using

Create a code block with class `.tikz`:

````markdown
```{.tikz}
%%| filename: stick-figure
%%| caption: A Stick Figure

\begin{tikzpicture}
  % Head
  \draw (0,0) circle (1cm);
  % Body
  \draw (0,-1) -- (0,-3);
  % Arms
  \draw (-1,-2) -- (0,-1) -- (1,-2);
  % Legs
  \draw (-1,-4) -- (0,-3) -- (1,-4);
\end{tikzpicture}
```
````

This should appear in the output as an image

![A stick figure rendered from the TikZ block above](images/stick-figure.svg)

## Captions and cross-references

There are two ways to give a diagram a caption, and they exist for
**different goals**. Pick by whether you need to refer to the figure
from prose.

**1. `%%| caption:` inside the block — for a caption only.** As in the
example above: the filter wraps the image in a figure carrying that
caption. The figure's `id` and `name` come from `%%| label:` and
`%%| name:` (and any `fig-`-prefixed directive or fence attribute), but
those don't reliably survive Quarto's float handling, so a figure made
this way is **not dependably cross-referenceable** with `@fig-…`.

**2. Quarto's native fenced div — for `@fig-…` cross-references.**

````markdown
::: {#fig-stick}
```{.tikz}
%%| filename: stick-figure
\begin{tikzpicture}...\end{tikzpicture}
```

A Stick Figure
:::
````

Here Quarto owns the float, so `@fig-stick` resolves correctly. Use this
whenever you need to reference the figure in text; it is the pattern the
bundled [`example.qmd`](example.qmd) uses.

| You want… | Use |
|---|---|
| Just a caption under the diagram | `%%\| caption:` |
| A `@fig-…` cross-reference in prose | Quarto fenced div `::: {#fig-…}` |
| Both caption *and* cross-reference | Fenced div, with the caption as the div's last line |

> [!WARNING]
> **Don't do both at once.** Set `%%| caption:` *and* wrap the same
> block in a captioned `::: {#fig-…}` div, and the filter's figure gets
> nested inside Quarto's — a figure-within-a-figure with a doubled or
> empty caption. With the fenced div, leave `%%| caption:` out and let
> the div's last line be the caption.

## Renderers

Two rendering pipelines are available. Both consume the same `.tikz` block syntax, so switching between them rewrites no blocks. They answer *how* a diagram is drawn; a separate option, [`latex-passthrough`](#latex-passthrough), answers *whether* to draw it at all. The two are independent, so a project can pass source through to its PDF build and still render the same diagrams for the web.

- **`renderer: latex`** (default) — compiles each block server-side via the configured `tex-engine` (default `pdflatex`) and, for non-PDF outputs, the configured `svg-engine` (default `inkscape`). For PDF output, the intermediate PDF is embedded directly. Works for every output format Quarto supports. Requires a TeX distribution; for non-PDF outputs also a PDF/DVI → SVG converter.
- **`renderer: tikzjax`** — emits a `<script type="text/tikz">…</script>` tag and loads [TikZJax](https://github.com/artisticat1/obsidian-tikzjax) so the reader's browser renders the diagram client-side via WebAssembly. **No LaTeX or SVG converter needed**, but only works for HTML output and adds ~3 MB of JS/WASM to the first page load. Non-HTML outputs (PDF, docx, …) drop `tikzjax` blocks with a warning — use `renderer: latex` for those.

Pick the renderer document- or project-wide:

```yaml
tikz:
  renderer: tikzjax
```

…or per-block:

````markdown
```{.tikz}
%%| renderer: tikzjax
\begin{tikzpicture}…\end{tikzpicture}
```
````

The TikZJax assets come from `https://tikzjax.com/v1/` by default. Set `tikz.tikzjax-url` to self-host or to pin a fork (e.g. [drgrice1/tikzjax](https://github.com/drgrice1/tikzjax)); the URL you supply must serve both `tikzjax.js` and `fonts.css` at its root.

### Inline SVG for HTML

By default a rendered diagram reaches an HTML page as
`<img src="….svg">`, and a browser renders an SVG referenced that way in
**secure static mode**: the document inside the image is walled off from
the host page. Labels are neither selectable nor findable with
find-in-page, screen readers see no further than `alt`, and page CSS
cannot reach the diagram at all.

`embed: inline` emits the SVG as markup instead:

```yaml
tikz:
  embed: inline
```

…or per-block with `%%| embed: inline`. It applies only to HTML-family
output — PDF, docx and the rest keep a real image — and changes only how
the SVG is delivered, never the bytes, so switching it on invalidates no
cache entry.

**This is what makes `svg-engine: dvisvgm` worth choosing.** dvisvgm
emits real `<text>` elements and embeds fonts as WOFF, where `inkscape`
and `pdftocairo` outline every glyph to a path. Through an `<img>` that
advantage is unreachable by construction, so the choice collapses to
file size; inlined, it is the whole difference. `%%| alt:` becomes the
SVG's `<title>`, an accessible name that does not suppress the text
inside it, and every `<svg>` carries `class="tikz-svg"` as a styling
hook.

> [!NOTE]
> Inside an `<img>`, an SVG's `id`s, CSS classes and `@font-face`
> families are sandboxed; inlined they are page-global, and every
> converter repeats the same names from diagram to diagram. So the
> filter renames them per diagram before emitting — without that,
> `pdftocairo`'s `<use xlink:href="#glyph-0-0">` silently picks up the
> *first* diagram's glyphs, and `dvisvgm`'s `text.f0` gets redefined by
> a later diagram's font and size. If you post-process the emitted SVG
> yourself, do not assume the names match what the converter wrote.

## Sharing styles between diagrams

To reuse a `\tikzset` or a `\usepackage` block across many diagrams, put
it in a file alongside your `.qmd` and `\input` (or `\usepackage`) it
from each TikZ block. The extension sets `TEXINPUTS` before invoking the
TeX engine, so lookups resolve in this order:

1. The directory containing the source `.qmd`.
2. The extension's own directory (`_extensions/tikz/`), so shared style
   files can ship with the extension itself.
3. Your system's default LaTeX search path, so `\usepackage{tikz}` and
   friends keep working.

So a `shared-styles.tex` next to your `.qmd` holding
`\tikzset{myedge/.style={->, red, thick}}` is reachable from any block:

````markdown
```{.tikz}
\input{shared-styles.tex}
\begin{tikzpicture}
  \draw[myedge] (0,0) -- (2,0);
\end{tikzpicture}
```
````

The same mechanism works for a bundled `.sty` file (e.g.
`\usepackage{shared-styles}`) placed either next to the `.qmd` or inside
`_extensions/tikz/`.

## Example

A minimal worked document: [example.qmd](example.qmd).

## Caching

Compiling TikZ is slow — every diagram is at least a TeX compile and,
for non-PDF outputs, an SVG conversion. An optional content-addressed
cache avoids recompiling unchanged diagrams. Enable it from your
project's `_quarto.yml` (or any single document's front-matter):

```yaml
tikz:
  cache: true
```

By default, cached SVGs are written to a per-user cache directory:

- Linux/macOS: `$XDG_CACHE_HOME/tikz-diagram-filter/` (falls back to
  `~/.cache/tikz-diagram-filter/` if `XDG_CACHE_HOME` is unset).
- Windows: `%USERPROFILE%\.cache\tikz-diagram-filter\`.

Cache files are named `<basename>.<short-hash>.<ext>` (e.g.
`stick-figure.318b4ef1.svg`). The basename comes from the block's
`%%| filename:` directive (or `tikz` if you didn't set one); the short
hash covers the TikZ code plus the per-block options, the TeX engine,
the SVG engine, the template and the output format, so toggling any of
those produces a different file. Options are encoded canonically before
hashing — keys sorted, each key and value length-prefixed — so that
neither Lua's unspecified iteration order nor two similar option sets
can collide the names.

The code half has the `%%|` directive lines removed first. They are TeX
comments, so they cannot change a rendered byte, and the ones that *do*
influence compilation — `additionalPackages`, `header-includes`,
`renderer`, `opt-*` — are folded into the options half separately, as
the values they *resolve to* rather than as the text you wrote. So a
directive resolving to its default is invisible to the key: a no-op
`%%| renderer: latex`, or a value the filter rejected and warned about,
hashes the same as no directive at all. `embed` and `latex-passthrough`
never reach it either — the first changes only how already-rendered
bytes are delivered, and under the second nothing is cached. What is
left is presentation: `caption`, `alt`, `label`, `name`, `filename`.
Adding a caption, or migrating from `{.tikz filename='x'}` to
`%%| filename: x`, therefore leaves the entry intact rather than
silently orphaning it.

Every artifact a diagram produces is named that way — cache entries, the
mediabag, a `save-tex` tree alike — so an `ls` of any of them says which
diagram each file came from, and two blocks sharing an explicit
`filename` still get a file each.

> [!NOTE]
> A release that changes the key rekeys the cache: the first render
> after upgrading recompiles every diagram and orphans the old entries,
> which are harmless — `rm -rf` the cache dir to tidy up. If you commit
> an in-tree `cache-dir`, do that render on a machine that has TeX and
> expect one large diff, or a TeX-less build host will fail on the next
> build. [CHANGELOG.md](CHANGELOG.md) says which releases did.

`tikz.cache-dir: <path>` overrides the location. For solo local
development leave it unset; the user-level default is what you want.
**For projects deployed to a build host that has no TeX or Inkscape**
(Netlify, etc.), set an in-tree `cache-dir` and commit it — see the
[cached deployment recipe](#cached-deployment-to-a-build-host-without-texinkscape-netlify-etc).

Cleanup of the user-level cache is manual — `rm -rf` the cache dir
occasionally, or `find <cache-dir> -mtime +30 -delete` for a time-based
sweep. (Entries are not touched on hit, so `-mtime` reflects last write
rather than last use:
[#10](https://github.com/danmackinlay/quarto_tikz/issues/10), PRs
welcome.)

A proper Quarto language engine would handle all this more cleanly than
a homegrown cache, but writing one is more work than this project can
justify right now.

## Debugging a diagram

A diagram that cannot be rendered — no TeX engine on the machine, a
LaTeX error in the block, a missing SVG converter — is reported once,
naming the figure and the cause, and its block is left in the output as
its own source. The rest of the document renders normally: one broken
diagram is a cosmetic gap, never a failed build. That matters most on a
build host that has no TeX because it renders from a committed cache.

To diagnose a block that comes out wrong or won't compile, look at the
intermediate files (`.tex`, `.pdf` or `.dvi`, and `.log`) the TeX engine
actually saw. The filter can preserve those, but **only with caching
switched off**:

```yaml
# in the offending document's front-matter, temporarily
tikz:
  cache: false
  save-tex: true
  tex-dir: tikz-tex   # any path; defaults to 'tikz-tex'
```

Re-render and inspect `<tex-dir>/<filename>/`. Running your configured
TeX engine by hand from inside that directory reproduces the exact
compilation, and the `.log` is usually enough to spot the problem.

`cache: true` and `save-tex: true` are mutually exclusive: a cache hit
short-circuits compilation, so no intermediates would ever be written.
Set both and the filter warns and disables `save-tex`. So debugging is a
brief detour — switch caching off, debug, revert. Stale `tex-dir` trees
are safe to delete afterwards, and worth adding to `.gitignore`.

## PDF output

Under PDF output the extension skips SVG conversion entirely and embeds
each diagram's intermediate PDF via `\includegraphics`. That preserves
vector fidelity and fonts, and means **no SVG converter is required when
you only render to PDF.** (For HTML and the rest, that PDF — or a DVI,
under `svg-engine: dvisvgm` — goes through the configured converter
instead.) If you'd rather ship the TikZ source than an embedded PDF, see
[LaTeX passthrough](#latex-passthrough).

Blocks with `renderer: tikzjax` are dropped with a warning under PDF or
any other non-HTML output, since client-side JS can't run there — unless
`latex-passthrough: true`, which is checked first and hands the source
to the host document, so a tikzjax project still gets its diagrams into
the PDF. Mixing renderers in one document is fine: only the
tikzjax-tagged blocks are skipped.

## LaTeX passthrough

Under LaTeX output, `latex-passthrough` hands the TikZ source to the
host document as raw LaTeX instead of compiling it. The diagram is
typeset by the same LaTeX run as the surrounding text: no standalone
compile, no figure files, no `\includegraphics`. Fonts and sizing match
the document automatically, and the shipped `.tex` keeps the diagram's
source rather than an opaque binary — a couple of KB of TikZ against
tens of KB of rendered PDF, which is what an arXiv-style source
submission wants.

```yaml
tikz:
  latex-passthrough: true
```

…or per-block, mixing freely with compiled blocks in the same document:

````markdown
```{.tikz}
%%| latex-passthrough: true
\begin{tikzpicture}…\end{tikzpicture}
```
````

**It is not a renderer, and deliberately so.** It applies to exactly one
output family — `quarto.doc.isFormat('pdf')`, covering `format: pdf` and
`format: latex` alike — and says nothing about the others, where
`renderer` still decides. So the flag is safe to set project-wide, and
the combination you probably want for a paper with a web preview is two
lines:

```yaml
tikz:
  renderer: tikzjax        # HTML: rendered in the reader's browser
  latex-passthrough: true  # LaTeX: source handed to the host document
```

That builds the PDF with no TeX subprocess and the site with no TeX
installed at all. With the default `renderer: latex` instead, the HTML
build compiles each diagram to SVG as usual. For a different setting per
output *format*, `tikz:` merges from format-level metadata like any
other key — that is Quarto's job, not this filter's:

```yaml
format:
  html: {tikz: {renderer: tikzjax}}
  pdf:  {tikz: {latex-passthrough: true}}
```

### What reaches the host preamble

A captioned block becomes a `figure` environment, which is a **TeX
group** — and that single fact explains everything below. PGF records
"library loaded" *globally* while a library's own definitions stay local
to the group, and a `\tikzset` is local too. So anything declared inside
a captioned block is discarded at `\end{figure}`; in the library case
every later load is also suppressed, so a *different, later* block fails,
with an error naming PGF math rather than library loading.

The filter therefore hoists into the host preamble via
`include-in-header`:

- `\usepackage{tikz}` — Quarto's LaTeX template does not load it.
- The block's `%%| additionalPackages:` and `%%| header-includes:` text,
  verbatim. A `\tikzset` you want document-wide belongs here.
- Every `\usetikzlibrary{…}` in the block body, and likewise
  `\usepgfplotslibrary`, `\usepgflibrary` and `\usetikzmarklibrary`,
  emitted one library per line.

A load alone on its line (leading whitespace and a trailing `%` comment
are fine) is **moved**. One sharing its line with other code is
**copied** — excising it could break the drawing, and PGF's loaders are
idempotent, so the body's copy becomes a no-op. Three shapes are
reported rather than hoisted, each warning with the block and the line:
a loader **inside** a `tikzpicture` (it may be part of the drawing), one
whose argument does not brace-balance, and `\usepackage` or
`\usegdlibrary` anywhere in the body. Put those in
`%%| additionalPackages:`, which is hoisted verbatim and always works.

Hoisted text is deduplicated by exact string, so a dozen blocks opening
with the same loads collapse to one line each — but two that differ
only partially emit both. Harmless for a repeated `\usepackage{x}`; an
options clash (`\usepackage[a]{x}` against `\usepackage[b]{x}`) is a
LaTeX error, so keep package options consistent across a document.

`%%|` directive lines are stripped from the emitted LaTeX; they are
filter input, not part of the picture.

**Captions, and what passthrough ignores.** A `%%| caption:` block
becomes a `figure` with `\centering` and a `\caption`, exactly as under
either renderer; without a caption it is emitted bare, leaving placement
to the caller. (The [cross-referencing
caveats](#captions-and-cross-references) apply here too.) Since nothing
is compiled, `cache`, `save-tex`, `tex-engine`, `tex-template`,
`svg-engine` and `svg-command` have no effect, and neither do
`filename`, `alt`, or image attributes such as `width` — scale from
inside the block instead (`\begin{tikzpicture}[scale=2]`). `\input`-ing
a shared file still works, but resolution is the host LaTeX run's
business now, so keep such files beside the `.tex` you compile.

## Security

Rendering runs external programs (a TeX engine, and an SVG converter).
The options choosing *which* binary runs — `tikz.tex-engine`,
`tikz.svg-engine`, `tikz.svg-command` — are read **only** from
document/project metadata, never from per-block attributes or `%%|`
directives, so a hostile diagram *body* alone can't run a command.

Those programs are launched directly (`pandoc.pipe`), never through a
shell, so a value like `svg-engine: "x; rm -rf ~"` names a program that
does not exist rather than a pipeline that runs.

**Don't render untrusted documents.** Metadata is trusted input: an
attacker controlling the YAML front-matter can point `svg-command` at
any program. Separately, TeX can shell out via `\write18` if
shell-escape is enabled (this filter doesn't pass `-shell-escape`, but a
wrapper or site `texmf.cnf` might). To harden a pipeline, pin the
`tikz:` block in `_quarto.yml` so documents can't override it (the
hardening pattern from [pandoc-ext/diagram][pandoc-ext-diagram]).

## Configuration reference

Document- or project-level options (set under `tikz:` in the YAML
front-matter or `_quarto.yml`):

> **Note on document- vs project-level merging.** A `tikz:` block in a
> document's front-matter **replaces** the project-level one wholesale —
> Quarto does not deep-merge user-defined config keys. So a per-doc
> `tikz: { cache: true }` meant as a benign repeat drops every other
> setting (`cache-dir`, `svg-engine`, `renderer`, …) from `_quarto.yml`
> and silently falls back to the filter defaults. If you need a per-doc
> override, repeat every project-level setting you still want;
> otherwise omit the doc-level `tikz:` block entirely. (`filters: - tikz`
> is separate: required per-doc, and unaffected by this.)

Booleans accept `true`/`false`, `yes`/`no` and `1`/`0`, quoted or not;
anything else warns and leaves the default in place.

- `cache` — boolean, default `false`. Enable the on-disk SVG cache.
- `cache-dir` — path. Defaults to `$XDG_CACHE_HOME/tikz-diagram-filter`
  (or your platform's per-user cache equivalent). Leave unset unless you
  have a specific reason.
- `save-tex` — boolean, default `false`. Preserve intermediate
  `.tex`/`.pdf`/`.log` files for debugging. Ignored (with a warning)
  when `cache: true`.
- `tex-dir` — path, default `tikz-tex`. Where preserved intermediates
  land when `save-tex` is on.
- `tex-template` — path. If set, the contents of this file replace the
  built-in `\documentclass[tikz]{standalone}` template. Useful for
  loading `fontspec`, `babel`, custom colour packages, etc. The
  template is a [Pandoc template](https://pandoc.org/MANUAL.html#templates),
  so it must include `$additional-packages$`, `$for(header-includes)$
  $it$ $endfor$`, and `$body$`. Path is resolved relative to the qmd
  directory.
- `tex-engine` — string, default `pdflatex`. The LaTeX executable to
  invoke: `pdflatex`, `lualatex`, `xelatex`, or any other TeX engine on
  your `PATH`. Reach for `lualatex` / `xelatex` when you need `fontspec`,
  Unicode shaping or modern font features — see the
  [non-Latin scripts recipe](#non-latin-scripts-arabic-devanagari-).
- `svg-engine` — string, default `inkscape`. PDF/DVI → SVG converter:
  - `inkscape` — the default; consumes the PDF the TeX engine produced.
  - `pdftocairo` — from `poppler-utils`. Lightweight alternative if you
    don't want to install Inkscape; also consumes PDF.
  - `dvisvgm` — consumes a DVI (the filter asks the TeX engine for one in
    that mode) and embeds fonts as WOFF, keeping text in the rendered SVG
    selectable. Requires a TeX-Live-integrated `dvisvgm`; standalone
    packages may fail to find PostScript prologue files.

  `svg-engine` has no effect under LaTeX output, where the TeX run's own
  PDF is embedded directly and no converter runs at all.
- `svg-command` — string or list. Escape hatch for wiring any other
  PDF → SVG converter (`pdf2svg`, a `pymupdf` script, `mutool draw`, …)
  without us having to bless each tool individually. The first element
  is the executable, the rest are arguments, with `{input}` and
  `{output}` substituted with the intermediate PDF and the target SVG.
  A command naming neither placeholder is rejected. When set,
  `svg-command` takes precedence over `svg-engine` — setting both warns,
  and `svg-engine` is ignored. `{input}` is always a PDF: a custom
  command cannot consume the DVI that `svg-engine: dvisvgm` would
  otherwise ask the TeX engine for.

  Two YAML forms are accepted — `svg-command: "pdf2svg {input}
  {output}"`, or the equivalent list, which is what you want if any path
  may contain whitespace:

  ```yaml
  tikz:
    svg-command: [pdf2svg, "{input}", "{output}"]
  ```
- `renderer` — string, default `latex`. Picks the rendering pipeline:
  `latex` (server-side `tex-engine` + `svg-engine` chain above) or
  `tikzjax` (client-side WebAssembly rendering, HTML output only). See
  [Renderers](#renderers). An unrecognized value warns and is ignored, so
  the next source down applies — for a `%%|` directive that is the
  document-level `renderer`, and for the document-level setting it is the
  `latex` default. The same holds for `embed`.
- `latex-passthrough` — boolean, default `false`. Under LaTeX output
  (`format: pdf` or `format: latex`), emit the TikZ source into the host
  document instead of rendering it. Independent of `renderer`, which
  continues to govern every other output format. See
  [LaTeX passthrough](#latex-passthrough).
- `embed` — string, default `img`. How a rendered SVG reaches an HTML
  page: `img` (an `<img src=…>` reference) or `inline` (the SVG as
  markup, with its internal names namespaced per diagram). HTML-family
  output only; everything else keeps a real image. Does not affect the
  cache. See [Inline SVG for HTML](#inline-svg-for-html).
- `tikzjax-url` — string, default `https://tikzjax.com/v1`. Base URL
  for the TikZJax `tikzjax.js` and `fonts.css` assets when
  `renderer: tikzjax`. Override to self-host or pin a fork.

Per-block directives (set inside the TikZ code block as `%%| key:
value` lines, as in [`example.qmd`](example.qmd)). These may also be
given as code-block fence attributes (`{.tikz filename=…}`, the
deprecated pre-1.0 form) — but if a key is set both ways the `%%|`
directive wins and the fence attribute is ignored with a warning:
`{.tikz filename='bayesnet-3'}` wrapped around a `%%| filename:
bayesnet-4` renders as `bayesnet-4`. Don't set the same option in
both places:

- `filename` — basename for the generated `.tex`/`.pdf`/`.svg`. Defaults
  to a hash of the code.
- `caption` — figure caption (Markdown). Produces a caption only, not
  a reliable cross-reference target — see
  [Captions and cross-references](#captions-and-cross-references).
- `alt` — image alt text.
- `label` — the figure's `id`; `name` — the figure's `name`. Not
  dependably honoured for cross-references; see
  [Captions and cross-references](#captions-and-cross-references).
- `additional-packages` (also accepted as `additionalPackages`) — extra
  `\usepackage{…}` lines added to the preamble of the synthesized LaTeX
  document (under `latex-passthrough`, to the host document's preamble).
- `header-includes` — additional raw LaTeX inserted into the preamble
  (same destinations as `additionalPackages`).
- `renderer`, `latex-passthrough`, `embed` — per-block overrides of the
  document-level settings above, taking the same values. So a single
  diagram can be passed through in an otherwise compiled document, or
  compiled in an otherwise passed-through one.

Attributes prefixed with `fig-`, `image-`/`img-`, or `opt-` are routed
to the figure, the image, or the per-block options respectively, whether
they are written as `%%|` directives or on the code block fence.

A `%%|` directive that names none of the above warns: an unrecognised
name is passed through as an image attribute (say so explicitly with
`%%| image-…:` to silence it), and one that names a *document-level*
option — `%%| cache: true`, say — is reported and ignored, because that
option only has an effect under `tikz:` in the front matter or
`_quarto.yml`. Fence attributes are not held to this: an arbitrary image
attribute is exactly what a fence attribute is for.

## Recipes

Three common end-to-end setups, each fully worked.

### Inkscape-free CI (TinyTeX on GitHub Actions, etc.)

Inkscape is heavy (~200 MB with X dependencies on Linux), and most
minimal CI images don't ship it. `dvisvgm` ships with TeX Live, so on
any runner that already has TeX you can avoid Inkscape entirely:

```yaml
# _quarto.yml
tikz:
  svg-engine: dvisvgm
```

GitHub Actions workflow:

```yaml
# .github/workflows/build.yml
jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: quarto-dev/quarto-actions/setup@v2
        with:
          tinytex: true
      - run: tlmgr install dvisvgm
      - uses: quarto-dev/quarto-actions/render@v2
```

The `tlmgr install` line is needed because TinyTeX is deliberately
minimal — `dvisvgm` is in TeX Live but not pre-installed. It costs a few
MB, nothing like Inkscape.

Caveat: blocks relying on PostScript specials (some `pgfplots` 3-D
constructs, certain transparency tricks) may not come out identical via
DVI. The bulk of TikZ usage — graphical models, flowcharts, causal
diagrams — is unaffected.

### Non-Latin scripts (Arabic, Devanagari, …)

`pdflatex` can't handle complex-shaping scripts. Switch the TeX
engine to `lualatex` and supply a `fontspec`+`babel` template:

```yaml
# _quarto.yml
tikz:
  tex-engine: lualatex
  tex-template: tikz-fontspec.tex
```

A minimal `tikz-fontspec.tex` for Arabic (or other RTL scripts —
swap the babel font for your script's preferred face):

```latex
% tikz-fontspec.tex — drop next to your qmd
\documentclass[tikz]{standalone}

\usepackage{fontspec}
\usepackage[bidi=basic]{babel}

% Arabic. `Amiri` ships with TeX Live, so no extra install needed.
\babelprovide[import=ar]{arabic}
\babelfont[arabic]{rm}{Amiri}

% Devanagari example (uncomment if you need it; needs a Devanagari
% font installed on the machine, e.g. via `tlmgr install` or system).
% \babelprovide[import=hi]{hindi}
% \babelfont[hindi]{rm}{Noto Serif Devanagari}

$additional-packages$
$for(header-includes)$
$it$
$endfor$
\begin{document}
$body$
\end{document}
```

Then any `.tikz` block can use `\foreignlanguage{arabic}{…}` and the
other `babel` macros to mix scripts with the rest of its content. The
template is loaded once at filter setup and applied to every block in
the project, so individual blocks need no extra preamble. This is the
fix for "Arabic comes out garbled" under the default `pdflatex`
pipeline; no custom `pymupdf` step or forked extension required.

### Cached deployment to a build host without TeX/Inkscape (Netlify, etc.)

Many static-host build environments (Netlify, Vercel, GitHub Pages via
Actions without TinyTeX) have no TeX or Inkscape and no way to install
them. Cache hits never invoke a subprocess, so if every block hits the
cache the build host needs nothing.

```yaml
# _quarto.yml
tikz:
  cache: true
  cache-dir: _tikz-cache   # in-tree, so it travels with the repo
```

Track `_tikz-cache/` in git (i.e. **do not** add it to `.gitignore`) and
commit cache files alongside your `.qmd` changes. The build host clones
the repo, the cache comes with it, and every block returns its stored
SVG/PDF without invoking anything.

The workflow: edit a block locally, `quarto render` to populate the
cache, then `git add _tikz-cache/ <your-qmd>` and push. Because cache
filenames carry the diagram's basename, a `git diff --stat` of those
commits tells you which diagrams changed.

Forget the render step and the build host takes a cache miss: it logs an
error and emits the raw code block in place of the diagram. The build
still succeeds — the missing diagram is your signal.

## Tests

The filter's pure helpers have unit tests: the `%%|` directive parser and
option router, the `latex-passthrough` library-loader matching and
move/copy split, the cache-key encoding and option resolution, the
compile failure paths, and the inline-SVG namespacing. Each suite is a
file under `tests/`, sharing the assertion helper in `tests/harness.lua`.
Run them all from the repo root:

```sh
sh tests/run.sh
```

…or one at a time, e.g. `pandoc lua tests/test_cache_key.lua`.

They need nothing beyond `pandoc`, which the extension already requires —
no TeX distribution, no SVG converter — which is what lets CI
(`.github/workflows/test.yml`) run them on every push and pull request.

## Credits

Created by cribbing the tricks from [knitr/inst/examples/knitr-graphics.Rnw ](https://github.com/yihui/knitr/blob/master/R/engine.R#L348) and [data-intuitive/quarto-d2/](https://github.com/data-intuitive/quarto-d2/).
After spending 2 days of my life getting this working, I found that [there is a worked example of a tikz filter in pandoc itself](https://pandoc.org/lua-filters.html#building-images-with-tikz).
For many diagram languages in one filter, prefer the mature generalist
[pandoc-ext/diagram][pandoc-ext-diagram] (Asymptote, GraphViz, Mermaid,
PlantUML, TikZ, Typst/cetz, D2); some choices here are informed by it.
This project does *only* TikZ, trading generality for a cache key that
folds in engine/template/format (theirs keys on source text alone, so
caching is off by default), `TEXINPUTS` support for shared
`\input`/preamble files, and a debuggable on-disk cache (the basis of
the [no-TeX-on-the-build-host recipe](#cached-deployment-to-a-build-host-without-texinkscape-netlify-etc)).
Both let you pick between Inkscape, `dvisvgm`, and other backends.

[pandoc-ext-diagram]: https://github.com/pandoc-ext/diagram/tree/main
