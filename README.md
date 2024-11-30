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
  Thus you cannot refer to the figure in the text.
- But if you use quarto’s fenced divs and give it a name like `#fig-my-diagram` things work fine.


## PDF output

This does produce PDFs which can be included in PDF output; I wonder if we could shortcut the PDF rendering and just output as plain LaTeX in that case to integrate into the main LaTeX rendering workflow?
I’m not suite sure how to handle the TikZ libraries in that case.

Pull requests welcome.

## Efficiency

This filter has optional execution caching.
If you use that, make sure you clean it up occasionally, as it will fill up your disk with diagrams.

A better implementation would use a language cache like other engines in quarto.
However, developing a a whole tikz language engine feels like a lot more work than I can justify for the current project.

## Credits

Created by cribbing the tricks from [knitr/inst/examples/knitr-graphics.Rnw ](https://github.com/yihui/knitr/blob/master/R/engine.R#L348) and [data-intuitive/quarto-d2/](https://github.com/data-intuitive/quarto-d2/).
After spending 2 days of my life getting this working, I found that [there is a worked example of a tikz filter in pandoc itself](https://pandoc.org/lua-filters.html#building-images-with-tikz).
There is a bigger and more powerful system [pandoc-ext/diagram](https://github.com/pandoc-ext/diagram/tree/main) which you might prefer to use instead.
It can “Generate diagrams from embedded code; supports Mermaid, Dot/GraphViz, PlantUML, Asymptote, and TikZ”.

~~The distinction between this and their project is that for this filter inkscape is not a dependency, and we can use the `dvisvgm` backend, but OTOH, their package is better tested, more capable and more general.~~
This distinction between this project and theirs is that we handle Figures IMO sanely and also are simpler.
