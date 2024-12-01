# TikZ Extension For Quarto

Render [PGF/TikZ](https://en.wikipedia.org/wiki/PGF/TikZ) diagrams in [Quarto](https://quarto.org/).

## Installing

```bash
quarto add danmackinlay/quarto_tikz
```

This will install the extension under the `_extensions` subdirectory.
If you're using version control, you will want to check in this directory.

## Using

Create a code block with class `.tikz`.

# Simple TikZ Diagram

Here is a simple TikZ diagram without additional packages or complex features:

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

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).

## Dependencies

* inkscape

## Known bugs

- all classes and ids are striped from the output figure if you specify them from inside the tikz block, despite my best efforts to explicitly attach them to the generated Figure.
  Thus you cannot refer to the figure in the text if you create a figure by specifying a caption in the tikz block.
  Probably this could be helped by usig the new [FloatRefTarget](https://quarto.org/docs/prerelease/1.4/lua_changes.html)
- But if you use quarto’s fenced divs and give it a name like `#fig-my-diagram` things work fine; see [example.qmd](example.qmd).


## PDF output

This does produce PDFs which can be included in PDF output; I wonder if we could shortcut the PDF rendering and just output as plain LaTeX in that case to integrate into the main LaTeX rendering workflow?
I’m not suite sure how to handle the TikZ libraries in that case.

Pull requests welcome.

## Efficiency

This filter has optional execution caching.
If you use that, make sure you clean it up occasionally, as it will fill up your disk with diagrams.

A better implementation would use a language cache like other engines in quarto.
However, developing a a whole tikz language engine feels like a lot more work than I can justify for the current project.


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

## Credits

Created by cribbing the tricks from [knitr/inst/examples/knitr-graphics.Rnw ](https://github.com/yihui/knitr/blob/master/R/engine.R#L348) and [data-intuitive/quarto-d2/](https://github.com/data-intuitive/quarto-d2/).
After spending 2 days of my life getting this working, I found that [there is a worked example of a tikz filter in pandoc itself](https://pandoc.org/lua-filters.html#building-images-with-tikz).
There is a bigger and more powerful system [pandoc-ext/diagram](https://github.com/pandoc-ext/diagram/tree/main) which you might prefer to use instead.
It can “Generate diagrams from embedded code; supports Mermaid, Dot/GraphViz, PlantUML, Asymptote, and TikZ”.

~~The distinction between this and their project is that for this filter inkscape is not a dependency, and we can use the `dvisvgm` backend, but OTOH, their package is better tested, more capable and more general.~~
This distinction between this project and theirs is that we handle Figures IMO sanely and also are simpler.
