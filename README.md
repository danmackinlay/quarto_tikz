# TikZ Extension For Quarto

Render [PGF/TikZ](https://en.wikipedia.org/wiki/PGF/TikZ) diagrams in [Quarto](https://quarto.org/).

## Installing

```bash
quarto add danmackinlay/quarto_tikz
```

This will install the extension under the `_extensions` subdirectory.
If you're using version control, you will want to check in this directory.

## Using

Create a code block with class `.tikz`. Here is a simple TikZ diagram without additional packages or complex features:

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

![](/images/stick-figure.svg)

## Captions and cross-references

There are two ways to give a diagram a caption, and they exist for
**different goals** — pick based on whether you need to refer to the
figure from prose.

**1. `%%| caption:` inside the block — for a caption only.**

````markdown
```{.tikz}
%%| filename: stick-figure
%%| caption: A Stick Figure

\begin{tikzpicture}...\end{tikzpicture}
```
````

The filter wraps the image in a figure with that caption. This is the
simplest option and is all you need if you just want a caption under
the diagram. The figure's `id`/`class` come from `%%| fig-attr:` /
`label:` / `name:`, but those attributes don't reliably survive
Quarto's float handling, so a figure made this way is **not
dependably cross-referenceable** with `@fig-…`.

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

Here Quarto owns the float, so `@fig-stick` resolves correctly. Use
this whenever you need to reference the figure in text. This is the
pattern the bundled [`example.qmd`](example.qmd) uses.

| You want… | Use |
|---|---|
| Just a caption under the diagram | `%%\| caption:` |
| A `@fig-…` cross-reference in prose | Quarto fenced div `::: {#fig-…}` |
| Both caption *and* cross-reference | Fenced div, with the caption as the div's last line |

> [!WARNING]
> **Don't do both at once.** If you set `%%| caption:` *and* wrap the
> same block in a `::: {#fig-…}` div that also carries a caption line,
> the filter emits a figure (because of `%%| caption:`) which Quarto
> then nests inside *its* figure — you get a figure-within-a-figure
> with a doubled or empty caption. When you use the fenced div, leave
> `%%| caption:` out of the block and let the div's last line be the
> caption.

## Renderers

Two rendering pipelines are available; both consume the same `.tikz` block syntax, so you can switch between them without rewriting blocks. They answer *how* a diagram is drawn. A separate option, [`latex-passthrough`](#latex-passthrough), answers *whether* to draw it at all — under LaTeX output you can hand the source to the host document instead. The two are independent, so a project can pass source through to its PDF build and still render the same diagrams for the web.

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

By default the TikZJax assets are loaded from `https://tikzjax.com/v1/`. Override with `tikz.tikzjax-url` if you want to self-host or pin a fork (e.g. [drgrice1/tikzjax](https://github.com/drgrice1/tikzjax)):

```yaml
tikz:
  renderer: tikzjax
  tikzjax-url: https://your.host/path/to/dist
```

The supplied URL must serve both `tikzjax.js` and `fonts.css` at its root.

### LaTeX passthrough

Under LaTeX output, `latex-passthrough` hands the TikZ source to the
host document as raw LaTeX instead of compiling it. The diagram is
typeset by the same LaTeX run as the surrounding text, so no standalone
compile happens, no figure files are produced and no `\includegraphics`
is emitted. Fonts and sizing match the document automatically, the
shipped `.tex` keeps the diagram's source rather than an opaque binary,
and the source package stays small — a couple of KB of TikZ against tens
of KB of rendered PDF, which is what an arXiv-style source submission
wants.

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
output family — `quarto.doc.isFormat('pdf')`, which covers `format: pdf`
and `format: latex` alike — and says nothing about the others. On every
other format `renderer` still decides, with no fallback for this filter
to invent. So the flag is safe to set project-wide, and the combination
you probably want for a paper with a web preview is two lines:

```yaml
tikz:
  renderer: tikzjax        # HTML: rendered in the reader's browser
  latex-passthrough: true  # LaTeX: source handed to the host document
```

That builds the PDF with no TeX subprocess and the site with no TeX
installed at all. With the default `renderer: latex` instead, the HTML
build compiles each diagram to SVG as usual.

If you need finer control — a different renderer per output format
rather than per block — that is Quarto's job rather than this filter's;
`tikz:` merges from format-level metadata like any other key:

```yaml
format:
  html:
    tikz: {renderer: tikzjax}
  pdf:
    tikz: {latex-passthrough: true}
```

**What reaches the preamble.** The standalone wrapper used to supply
things the host document doesn't, so the filter hoists them via
`include-in-header`:

- `\usepackage{tikz}` — Quarto's default LaTeX template does not load
  TikZ, so the filter adds it as soon as one passthrough block exists.
- The block's `%%| additionalPackages:` and `%%| header-includes:`
  text, verbatim.
- Every `\usetikzlibrary{…}` in the block body, and likewise
  `\usepgfplotslibrary`, `\usepgflibrary` and `\usetikzmarklibrary`.
  Libraries are emitted one per line, so
  `\usetikzlibrary{arrows, arrows.meta}` becomes two preamble lines.

  How the call is written decides whether it is *moved* or *copied*. A
  line that is exactly one library load — leading whitespace and a
  trailing `%` comment are fine — is hoisted and **removed** from the
  body, which keeps the shipped `.tex` tidy. A load that shares its line
  with other code cannot be excised without risking the drawing, so it
  is **copied**: the preamble gets the load and the body keeps its own.
  That is safe because PGF's loaders are idempotent — the preamble load
  wins and the body copy becomes a no-op.

  Copying is not merely tidiness. `\usetikzlibrary` is legal in the
  document body, but a **captioned** block is emitted inside a `figure`
  environment, and PGF records "library loaded" *globally* while the
  library's own definitions are local to the current group. A library
  loaded in there is therefore discarded at `\end{figure}` while every
  later load of it is suppressed — so a *different, later* block fails,
  with an error naming PGF math rather than library loading.

  Three cases are reported rather than hoisted, because relocating them
  could break the document: a loader **inside** a `tikzpicture` (it may
  be part of the drawing, and inventing a library name is a hard error),
  one whose argument does not brace-balance, and `\usepackage` or
  `\usegdlibrary` anywhere in the body. Each produces a warning naming
  the block and the line. Put those in `%%| additionalPackages:`, which
  is hoisted verbatim and always works.

Hoisted text is deduplicated by exact string, which is what makes it
safe for a dozen blocks to open with the same library loads: identical
lines collapse to one, and anything that differs is emitted in full
rather than merged. Two blocks whose `additionalPackages` differ only
partially therefore emit both lines — harmless for a repeated
`\usepackage{x}`, but an options clash (`\usepackage[a]{x}` in one
block, `\usepackage[b]{x}` in another) is a LaTeX error, so keep
package options consistent across a document.

The `%%|` directive lines themselves are stripped from the emitted
LaTeX; they are filter input, not part of the picture.

**Captions.** A block with `%%| caption:` becomes a `pandoc.Figure`,
exactly as on the other two renderers, which pandoc writes as a
`figure` environment with `\centering` and a `\caption`. A block
without a caption is emitted bare — no float, no centring — leaving
placement to the caller. (The cross-referencing caveats in
[Captions and cross-references](#captions-and-cross-references) apply
here too.)

That `figure` environment is a TeX group, so a `\tikzset` left in the
body of a captioned block applies only to that block, while the same
`\tikzset` in an uncaptioned block leaks to the rest of the document.
Under `renderer: latex` every block was its own `standalone` compile and
neither shared anything, so if you want a style available document-wide,
put it in `%%| header-includes:` rather than relying on either.

**What passthrough ignores.** Nothing is compiled, so `cache`,
`save-tex`, `tex-engine`, `tex-template`, `svg-engine` and
`svg-command` have no effect on passthrough blocks. Neither do
`filename` and `alt`, which name and describe an image file that is
never produced, nor image attributes such as `width` — scale the picture
from inside the block instead (`\begin{tikzpicture}[scale=2]`). Sharing styles by
`\input`-ing a file still works, but resolution is now the host LaTeX
run's business (the filter's `TEXINPUTS` handling doesn't apply), so
keep such files next to the `.tex` you compile.

## Sharing styles between diagrams

If you have a `\tikzset` or a `\usepackage` block that you want to reuse
across many diagrams, you can put it in a separate file alongside your
`.qmd` and `\input` (or `\usepackage`) it from each TikZ block. The
extension sets `TEXINPUTS` before invoking the TeX engine so that
lookups resolve in this order:

1. The directory containing the source `.qmd`.
2. The extension's own directory (`_extensions/tikz/`), so that you can
   ship shared style files together with the extension itself.
3. Your system's default LaTeX search path (so `\usepackage{tikz}` etc.
   continue to work as normal).

For example, drop a `shared-styles.tex` next to your `.qmd`:

```latex
% shared-styles.tex
\tikzset{myedge/.style={->, red, thick}}
```

Then use it from any TikZ block:

````markdown
```{.tikz}
\input{shared-styles.tex}
\begin{tikzpicture}
  \draw[myedge] (0,0) -- (2,0);
\end{tikzpicture}
```
````

The same mechanism works for a bundled `.sty` file (e.g.
`\usepackage{shared-styles}`) placed either next to the `.qmd` or
inside `_extensions/tikz/`.

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).

## Dependencies

You need a TeX distribution (TeX Live or MacTeX) on your `PATH`. For
HTML and other non-PDF outputs you also need a PDF/DVI → SVG
converter; by default that's `inkscape` (≥ 1.0), but you can pick a
different one via `tikz.svg-engine` (see the configuration reference
below). When you render only to PDF, no SVG converter is required —
the intermediate PDF is embedded directly.

`pdflatex` is invoked by default. To use `lualatex` or `xelatex` (e.g.
for `fontspec` / complex Unicode scripts), set `tikz.tex-engine`
accordingly — see the configuration reference below.

Under `renderer: tikzjax` (HTML output only) none of the above is
required: rendering happens in the reader's browser via WebAssembly.
See [Renderers](#renderers).

For minimal CI environments without Inkscape (e.g. TinyTeX on GitHub
Actions), see the [Inkscape-free CI recipe](#inkscape-free-ci-tinytex-on-github-actions-etc)
below.

## Caching

Compiling TikZ is slow — every diagram is at least a TeX compile and,
for non-PDF outputs, an SVG conversion step. The filter has an
optional content-addressed cache to avoid recompiling unchanged
diagrams.

Enable it from your project's `_quarto.yml` (or any single document's
front-matter):

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
`%%| filename:` directive (or `tikz` if you didn't set one), and the
short hash is derived from the TikZ code plus per-block options, the
TeX engine, the SVG engine, the template, and the output format —
toggling any of those produces a different cache file. A `ls` of the
cache directory is therefore enough to tell at a glance which diagram
in which document each entry came from.

You can override the location with `tikz.cache-dir: <path>`. For
solo local development, the default user-level cache is the
recommended setup — leave `cache-dir` unset. **For projects deployed
to a build host that doesn't have TeX or Inkscape** (Netlify, etc.),
set an in-tree `cache-dir` and commit it; see the [cached deployment
recipe](#cached-deployment-to-a-build-host-without-texinkscape-netlify-etc)
below.

Cleanup of the user-level cache is manual — `rm -rf` the cache dir
occasionally, or `find <cache-dir> -mtime +30 -delete` if you want a
time-based sweep.

Known follow-ups (PRs welcome):

- [#10](https://github.com/danmackinlay/quarto_tikz/issues/10) — touch
  cache entries on hit so an external `find -mtime`-based GC reflects
  actual last use.

A proper Quarto language engine would handle this more cleanly than a
homegrown cache, but writing one is more work than this project can
justify right now.

## Debugging a diagram

When a TikZ block silently produces something wrong (or fails to
compile), the quickest way to diagnose it is to look at the intermediate
files (`.tex`, `.pdf` or `.dvi`, and `.log`) the TeX engine actually
saw. The filter can preserve those for inspection, but **only with
caching switched off** (see below):

```yaml
# in the offending document's front-matter, temporarily
tikz:
  cache: false
  save-tex: true
  tex-dir: tikz-tex   # any path; defaults to 'tikz-tex'
```

Re-render the document and inspect the contents of
`<tex-dir>/<filename>/`. Running your configured TeX engine (default
`pdflatex`) by hand from inside that directory reproduces the exact
compilation, and the `.log` is usually enough to spot the problem.

`cache: true` and `save-tex: true` are mutually exclusive: a cache hit
short-circuits compilation, so no intermediates would ever be written.
If both are set, the filter logs a warning and disables `save-tex`. So
debugging is a brief detour: switch caching off, debug, then revert.

`tex-dir` is otherwise inert under `cache: true`. Stale `tikz-tex/`
directories from previous debugging sessions are safe to delete —
nothing in the rendered HTML references them. You'll usually want to add
your `tex-dir` to `.gitignore`.

## PDF output

When the Quarto output format is PDF (e.g. `format: pdf`), the
extension skips the SVG conversion step entirely and embeds each TikZ
diagram's intermediate PDF directly via `\includegraphics`. This
preserves vector fidelity and fonts in the rendered document, and
means **no SVG converter is required when you only render to PDF.**

For HTML and other non-PDF formats, the TeX engine's PDF (or DVI, if
you've set `svg-engine: dvisvgm`) is run through the configured SVG
converter to produce an embedded SVG. See the
[configuration reference](#configuration-reference) for `tex-engine`,
`svg-engine`, and `svg-command`.

If you'd rather ship the TikZ source than an embedded PDF — no figure
files, matched fonts, an editable `.tex` — set
`latex-passthrough: true`; see [LaTeX passthrough](#latex-passthrough).

Blocks with `renderer: tikzjax` are dropped (with a warning) under PDF
or any other non-HTML output, since client-side JS can't run there —
unless `latex-passthrough: true`, which is checked first and hands the
source to the host document, so a tikzjax project still gets its
diagrams into the PDF. Mixing renderers in the same document is fine —
only the tikzjax-tagged blocks are skipped.

Other features discussed in
[#5](https://github.com/danmackinlay/quarto_tikz/issues/5) (alternative
TeX engines, custom templates, alternative SVG converters) are tracked
separately. PRs welcome.

## Known bugs

Figure attributes set inside the TikZ block (via `%%| fig-attr:`,
`label:`, `name:`) don't always survive the round-trip into the
rendered output, so a figure captioned with `%%| caption:` is not
dependably cross-referenceable. The reliable pattern for `@fig-…`
references is to wrap the block in a Quarto fenced div instead — see
[Captions and cross-references](#captions-and-cross-references) above
for both methods, when to use each, and the figure-in-a-figure pitfall
to avoid.


## Upgrading from Previous Versions

Version **1.0.0** of `quarto_tikz` introduces several breaking changes. To ensure a smooth transition, please update your documents as follows:

### Diagram Syntax

Now you provide your own `tikzpicture` environment, rather than just the contents of the `tikzpicture` environment, to allow extra flexibility, for example the ability to invoke helpful directives such as
`\usetikzlibrary`, `
`\tikzstyle` and `\resizebox`.

Previously:

````markdown
```{.tikz }
% TikZ code
```
````
Now

````markdown
```{.tikz}
%%|format: svg
\begin{tikzpicture}
% TikZ code

\end{tikzpicture}
```
````

### Option Specification Syntax

Previously, options like `filename` and `caption` were set using code block attributes.
Now, they should be specified inside the code block using the `%%| key: value` comment syntax.

**Before:**
````markdown
```{.tikz filename="my-diagram" caption="An example diagram"}
% TikZ code
```
````

Now
````markdown
```{.tikz}
%%| filename: my-diagram
%%| caption: "An example diagram"

% TikZ code
```
````

The fence-attribute form still works for backward compatibility, but
**if you set the same option both ways, the `%%|` directive wins** and
the fence attribute is ignored (with a warning). For example:

````markdown
```{.tikz filename='bayesnet-3'}
%%| filename: bayesnet-4
% → renders as bayesnet-4; a warning notes bayesnet-3 was ignored
```
````

Don't set an option in both places. Pick the `%%|` form (it's the
canonical syntax and matches Quarto's cell-options convention) and
delete any leftover fence attribute.

(The sibling project [pandoc-ext/diagram][pandoc-ext-diagram]
independently reached the same conclusion — its Quarto notes tell users
to use the `%%|` comment-pipe form rather than fence attributes for the
filename. We go one step further by detecting the conflict and warning
rather than silently picking one.)

### Figure Attributes Handling

Figure attributes such as `id` and `class` can be set with the
`fig-attr` option inside the code block:

````markdown
```{.tikz}
%%| fig-attr:
%%|   id: fig-my-diagram
%%|   class: my-class

% TikZ code
```
````

…but attributes set this way don't reliably survive Quarto's float
handling, so for anything you need to cross-reference, prefer the
fenced-div pattern. See
[Captions and cross-references](#captions-and-cross-references) for the
full picture (both methods, when to use each, and the
figure-in-a-figure pitfall). The bundled [`example.qmd`](example.qmd)
uses the fenced-div form:

````
::: {#fig-example .test-class}
```{.tikz}
%%| filename: my-fancy-diagram
%%| fig-attr:
%%|   id: fig-my-fancy-diagram
%%|   class: my-class
%%| additionalPackages: \usepackage{adjustbox}

\usetikzlibrary{arrows}
\tikzstyle{int}=[draw, fill=blue!20, minimum size=2em]
\tikzstyle{init} = [pin edge={to-,thin,black}]

\resizebox{16cm}{!}{%
  \trimbox{3.5cm 0cm 0cm 0cm}{
    \begin{tikzpicture}[node distance=2.5cm,auto,>=latex']
      \node [int, pin={[init]above:$v_0$}] (a) {$\frac{1}{s}$};
      \node (b) [left of=a,node distance=2cm, coordinate] {a};
      \node [int, pin={[init]above:$p_0$}] at (0,0) (c)
        [right of=a] {$\frac{1}{s}$};
      \node [coordinate] (end) [right of=c, node distance=2cm]{};
      \path[->] (b) edge node {$a$} (a);
      \path[->] (a) edge node {$v$} (c);
      \draw[->] (c) edge node {$p$} (end) ;
    \end{tikzpicture}
  }
}
```

A fancy TikZ example
:::
````

### Including Additional LaTeX Packages

To include additional LaTeX packages, use the `additionalPackages` option within the code block comments instead of code block attributes.


````markdown
```{.tikz}
%%| additionalPackages: \usepackage{adjustbox}

% TikZ code
```
````

### Dependency Changes

The extension defaults to `pdflatex` for compilation and `inkscape`
for SVG conversion. Both are now configurable via `tikz.tex-engine`
and `tikz.svg-engine` (the latter also supports `dvisvgm` and
`pdftocairo`; for anything else, `tikz.svg-command` is an arbitrary
external command escape hatch). See the
[configuration reference](#configuration-reference) and the
[Recipes](#recipes) section. When you only render to PDF, no SVG
converter is required at all.

## Security

Rendering runs external programs (a TeX engine, and an SVG converter).
The options choosing *which* binary runs — `tikz.tex-engine`,
`tikz.svg-engine`, `tikz.svg-command` — are read **only** from
document/project metadata, never from per-block attributes or `%%|`
directives, so a hostile diagram *body* alone can't run a command.

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
> document's front-matter **replaces** the project-level `tikz:` block
> wholesale — Quarto does not deep-merge user-defined config keys. So a
> per-doc `tikz: { cache: true }` meant as a benign repeat will drop
> every other setting (`cache-dir`, `svg-engine`, `renderer`, …) from
> `_quarto.yml` and silently fall back to the filter defaults. If you
> need a per-doc override, repeat every project-level setting you still
> want; otherwise, omit the `tikz:` block at the doc level entirely and
> let project-level settings apply. (Note that `filters: - tikz` is
> separate — that line is required per-doc and unaffected by this
> merging behaviour.)

- `cache` — boolean, default `false`. Enable the on-disk SVG cache.
- `cache-dir` — path. Defaults to `$XDG_CACHE_HOME/tikz-diagram-filter`
  (or the per-user cache equivalent on your platform). Override only if
  you have a specific reason; otherwise leave unset.
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
- `tex-engine` — string, default `pdflatex`. Name of the LaTeX
  executable to invoke (`pdflatex`, `lualatex`, `xelatex`, or any other
  TeX engine on your `PATH`). `lualatex` / `xelatex` are useful when
  you need `fontspec`, Unicode shaping (Arabic, Devanagari, etc.) or
  modern font features — see the [non-Latin scripts recipe](#non-latin-scripts-arabic-devanagari-)
  for a worked example.
- `svg-engine` — string, default `inkscape`. PDF/DVI → SVG converter:
  - `inkscape` — the default; consumes the PDF produced by the TeX
    engine.
  - `pdftocairo` — from `poppler-utils`. Lightweight alternative if you
    don't want to install Inkscape; also consumes PDF.
  - `dvisvgm` — consumes a DVI (the filter automatically asks the TeX
    engine for DVI output in that mode) and embeds fonts as WOFF,
    keeping text in the rendered SVG selectable. Requires a
    TeX-Live-integrated `dvisvgm`; standalone packages may fail to find
    PostScript prologue files.
- `svg-command` — string or list. Escape hatch for wiring any other
  PDF → SVG converter (`pdf2svg`, a `pymupdf` script, `mutool draw`,
  etc.) without us having to bless each tool individually. The first
  element is the executable; subsequent elements are arguments, with
  `{input}` and `{output}` substituted with the intermediate PDF and
  the target SVG paths respectively. When set, `svg-command` takes
  precedence over `svg-engine`.

  Two YAML forms are accepted; prefer the list form if any path may
  contain whitespace:

  ```yaml
  tikz:
    svg-command: "pdf2svg {input} {output}"

  # or, equivalently:
  tikz:
    svg-command:
      - pdf2svg
      - "{input}"
      - "{output}"
  ```
- `renderer` — string, default `latex`. Picks the rendering pipeline:
  `latex` (server-side `tex-engine` + `svg-engine` chain above) or
  `tikzjax` (client-side WebAssembly rendering, HTML output only). See
  [Renderers](#renderers). An unrecognized value warns and falls back to
  `latex`.
- `latex-passthrough` — boolean, default `false`. Under LaTeX output
  (`format: pdf` or `format: latex`), emit the TikZ source into the host
  document instead of rendering it; `renderer` continues to govern every
  other output format. Independent of `renderer`, so the two can be set
  together. See [LaTeX passthrough](#latex-passthrough).
- `tikzjax-url` — string, default `https://tikzjax.com/v1`. Base URL
  for the TikZJax `tikzjax.js` and `fonts.css` assets when
  `renderer: tikzjax`. Override to self-host or pin a fork.

Per-block directives (set inside the TikZ code block as `%%| key:
value` lines, as in [`example.qmd`](example.qmd)). These may also be
given as code-block fence attributes (`{.tikz filename=…}`, the
deprecated pre-1.0 form) — but if a key is set both ways the `%%|`
directive wins and the fence attribute is ignored with a warning, so
don't set the same option in both places:

- `filename` — basename for the generated `.tex`/`.pdf`/`.svg`. Defaults
  to a hash of the code.
- `caption` — figure caption (Markdown). Produces a caption only, not
  a reliable cross-reference target — see
  [Captions and cross-references](#captions-and-cross-references).
- `alt` — image alt text.
- `fig-attr:` — nested block of Pandoc figure attributes (`id`,
  `class`, etc.). Not dependably honoured for cross-references; see
  [Captions and cross-references](#captions-and-cross-references).
- `additionalPackages` — extra `\usepackage{…}` lines added to the
  preamble of the synthesized LaTeX document (under
  `latex-passthrough`, to the host document's preamble).
- `header-includes` — additional raw LaTeX inserted into the preamble
  (same destinations as `additionalPackages`).
- `renderer` — `latex` or `tikzjax`. Per-block override of the
  document-level renderer.
- `latex-passthrough` — `true` or `false`. Per-block override of the
  document-level setting, so a single diagram can be passed through in
  an otherwise compiled document, or compiled in an otherwise
  passed-through one.

Attributes prefixed with `fig-`, `image-`/`img-`, or `opt-` on the code
block fence are routed to the figure, the image, or the per-block
options respectively.

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

`tlmgr install dvisvgm` is needed because TinyTeX is deliberately
minimal — `dvisvgm` is in TeX Live but not pre-installed. The package
itself is small (a few MB; nothing like Inkscape).

Caveat: if you build TikZ blocks that rely on PostScript specials
(some `pgfplots` 3-D constructs, certain transparency tricks), the
DVI route may not produce identical output. The bulk of TikZ usage —
graphical models, flowcharts, causal diagrams, etc. — is unaffected.

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

Then in any `.tikz` block you can use `\foreignlanguage{arabic}{…}`
or `\textsuperscript`-style macros provided by `babel` to mix scripts
with the rest of your TikZ content. The template is loaded once at
filter setup and applied to every block in the project, so individual
blocks don't need any extra preamble.

If you previously hit "Arabic comes out garbled" with the default
`pdflatex`+Inkscape pipeline (which doesn't shape complex scripts),
this is the fix — and you don't need a custom Python/`pymupdf` step
or a forked extension to get there.

### Cached deployment to a build host without TeX/Inkscape (Netlify, etc.)

Many static-host build environments (Netlify, Vercel, GitHub Pages
via Actions without TinyTeX) don't have TeX or Inkscape and you
can't install them. Cache hits never invoke any subprocess, so if
every block hits the cache, the build host needs nothing.

```yaml
# _quarto.yml
tikz:
  cache: true
  cache-dir: _tikz-cache   # in-tree, so it travels with the repo
```

Track `_tikz-cache/` in git (i.e. **do not** add it to `.gitignore`).
Commit cache files alongside your `.qmd` changes. The build host
clones the repo, the cache comes with it, and every `.tikz` block
hits the cache and returns its stored SVG/PDF without invoking
anything.

Workflow:

1. Edit a `.tikz` block locally.
2. `quarto render` — populates the cache.
3. `git add _tikz-cache/ <your-qmd>` and commit.
4. Push.

Cache filenames are `<basename>.<short-hash>.<ext>` (e.g.
`stick-figure.318b4ef1.svg`), so a `git diff --stat` of your cache
commits is human-readable: you can see which diagrams changed.

If you forget step 2 and push a `.tikz` change without re-rendering,
the build host gets a cache miss, fails the dependency check, logs
an error, and emits the raw code block in place of the diagram. The
build itself succeeds — the missing diagram is your signal.

## Tests

The pure helpers behind `latex-passthrough` — comment stripping,
library-loader matching, and the move/copy split — have unit tests. Run them
from the repo root:

```sh
pandoc lua tests/test_passthrough.lua
```

They need nothing beyond `pandoc`, which the extension already requires.

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
