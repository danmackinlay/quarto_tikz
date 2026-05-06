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

## Renderers

Two rendering pipelines are available; both consume the same `.tikz` block syntax, so you can switch between them without rewriting blocks.

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

## Sharing styles between diagrams

If you have a `\tikzset` or a `\usepackage` block that you want to reuse
across many diagrams, you can put it in a separate file alongside your
`.qmd` and `\input` (or `\usepackage`) it from each TikZ block. The
extension sets `TEXINPUTS` before invoking `pdflatex` so that lookups
resolve in this order:

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

## Caching

Compiling TikZ via `pdflatex` and Inkscape is slow, so the filter has an
optional content-addressed cache.

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

You can override the location with `tikz.cache-dir: <path>`, but doing so
scatters per-directory cache folders across the tree. **Leaving
`cache-dir` unset and using the default user-level cache is the
recommended setup.**

Cleanup today is manual — `rm -rf` the cache dir occasionally, or
`find <cache-dir> -mtime +30 -delete` if you want a time-based sweep.

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
`.tex`, `.pdf` and `.log` files that `pdflatex` actually saw. The
filter can preserve those for inspection, but **only with caching
switched off** (see below):

```yaml
# in the offending document's front-matter, temporarily
tikz:
  cache: false
  save-tex: true
  tex-dir: tikz-tex   # any path; defaults to 'tikz-tex'
```

Re-render the document and inspect
`<tex-dir>/<filename>/<filename>.{tex,pdf,svg,log}`. Running `pdflatex
<filename>.tex` by hand from inside that directory reproduces the exact
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
extension skips the Inkscape conversion step and embeds each TikZ
diagram's intermediate PDF directly via `\includegraphics`. This
preserves vector fidelity and fonts in the rendered document, and
means **Inkscape is not required when you only render to PDF.**

For HTML and other non-PDF formats, the existing `pdflatex` → Inkscape
→ SVG path is used.

Blocks with `renderer: tikzjax` are dropped (with a warning) under PDF
or any other non-HTML output, since client-side JS can't run there.
Mixing the two renderers in the same document is fine — only the
tikzjax-tagged blocks are skipped.

Other features discussed in
[#5](https://github.com/danmackinlay/quarto_tikz/issues/5) (alternative
TeX engines, custom templates, alternative SVG converters) are tracked
separately. PRs welcome.

## Known bugs

Figure attributes set inside the TikZ block (via `%%| fig-attr:`,
`label:`, `name:`) don't always survive the round-trip into the rendered
output. The reliable pattern is to wrap the block in a Quarto fenced
div, which is what the bundled [`example.qmd`](example.qmd) does:

````markdown
::: {#fig-my-diagram}
```{.tikz}
%%| filename: my-diagram
\begin{tikzpicture}…\end{tikzpicture}
```

Caption goes here.
:::
````

This makes `@fig-my-diagram` cross-references work correctly.


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

### Figure Attributes Handling

Figure attributes such as `id` and `class` are now set using the `fig-attr` option within the code block comments.
I think? TBH have not actually tested this

Use `fig-attr` to define figure attributes. For example:

````markdown
```{.tikz}
%%| fig-attr:
%%|   id: fig-my-diagram
%%|   class: my-class

% TikZ code
```
````

But actually figure attributes in Quarto are dark magic.
Life is easier if we simply use their fenced divs and give them a name like `#fig-my-diagram`.
See [example.qmd](example.qmd).

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

The extension now uses `pdflatex` and `inkscape` instead of the older `dvisvgm` and `ghostscript`.
There were certain advantages to that renderer; I wonder if we should support switchable backends?

Anyway, you need to ensure that both `pdflatex` and `inkscape` are installed and accessible in your system's PATH. If not, install them to avoid rendering issues.

## Configuration reference

Document- or project-level options (set under `tikz:` in the YAML
front-matter or `_quarto.yml`):

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
  modern font features.
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
  [Renderers](#renderers).
- `tikzjax-url` — string, default `https://tikzjax.com/v1`. Base URL
  for the TikZJax `tikzjax.js` and `fonts.css` assets when
  `renderer: tikzjax`. Override to self-host or pin a fork.

Per-block directives (set inside the TikZ code block as `%%| key:
value` lines, as in [`example.qmd`](example.qmd)):

- `filename` — basename for the generated `.tex`/`.pdf`/`.svg`. Defaults
  to a hash of the code.
- `caption` — figure caption (Markdown).
- `alt` — image alt text.
- `fig-attr:` — nested block of Pandoc figure attributes (`id`,
  `class`, etc.).
- `additionalPackages` — extra `\usepackage{…}` lines added to the
  preamble of the synthesized LaTeX document.
- `header-includes` — additional raw LaTeX inserted into the preamble.
- `renderer` — `latex` or `tikzjax`. Per-block override of the
  document-level renderer.

Attributes prefixed with `fig-`, `image-`/`img-`, or `opt-` on the code
block fence are routed to the figure, the image, or the per-block
options respectively.

## Credits

Created by cribbing the tricks from [knitr/inst/examples/knitr-graphics.Rnw ](https://github.com/yihui/knitr/blob/master/R/engine.R#L348) and [data-intuitive/quarto-d2/](https://github.com/data-intuitive/quarto-d2/).
After spending 2 days of my life getting this working, I found that [there is a worked example of a tikz filter in pandoc itself](https://pandoc.org/lua-filters.html#building-images-with-tikz).
There is a bigger and more powerful system [pandoc-ext/diagram](https://github.com/pandoc-ext/diagram/tree/main) which you might prefer to use instead.
It can “Generate diagrams from embedded code; supports Mermaid, Dot/GraphViz, PlantUML, Asymptote, and TikZ”.

~~The distinction between this and their project is that for this filter inkscape is not a dependency, and we can use the `dvisvgm` backend, but OTOH, their package is better tested, more capable and more general.~~
This distinction between this project and theirs is that we handle Figures IMO sanely and also are simpler.
