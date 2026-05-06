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

You need both `pdflatex` (TeX Live or MacTeX) and `inkscape` (≥ 1.0)
installed and on your `PATH`. The filter shells out to `pdflatex` to
build a PDF and then to Inkscape to convert that PDF to SVG.

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

Cache keys are the SHA1 of the TikZ code together with any per-block
options, so editing either invalidates the entry.

You can override the location with `tikz.cache-dir: <path>`, but doing so
scatters per-directory cache folders across the tree. **Leaving
`cache-dir` unset and using the default user-level cache is the
recommended setup.**

Cleanup today is manual — `rm -rf` the cache dir occasionally, or
`find <cache-dir> -mtime +30 -delete` if you want a time-based sweep.

Known follow-ups (PRs welcome):

- [#9](https://github.com/danmackinlay/quarto_tikz/issues/9) — include
  the diagram basename in the cache filename so a directory listing is
  human-diagnosable.
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

The extension always converts each diagram to SVG (via `pdflatex` →
Inkscape) and embeds that. There is currently no special path for PDF
output (e.g. directly embedding the intermediate PDF, using `lualatex`
for richer Unicode coverage, or accepting custom LaTeX templates). For
that broader set of features see the discussion and proposed work in
[#5](https://github.com/danmackinlay/quarto_tikz/issues/5). PRs welcome.

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
