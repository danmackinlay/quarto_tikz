# TikZ Extension For Quarto

Render [PGF/TikZ](https://en.wikipedia.org/wiki/PGF/TikZ) diagrams in [Quarto](https://quarto.org/).

## Installing


```bash
quarto add danmackinlay/tikz
```

This will install the extension under the `_extensions` subdirectory.
If you're using version control, you will want to check in this directory.

## Using

Create a code block with class `.tikz`.

````qmd
```{.tikz embed_mode="link" scale=3}
\node[draw, circle] (A) at (0,0) {A};
\node[draw, circle] (B) at (2,2) {B};
\node[draw, circle] (C) at (4,0) {C};
\node[draw, circle] (seven) at (5,1) {888888};
\draw[->] (A) -- (B);
\draw[->] (B) -- (C);
\draw[->] (C) -- (A);
```
````

Note that _if ghostscript is not installed on your system it will fail to render SVGs_.

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).


## Credits

Created by cribbing the tricks from [knitr/inst/examples/knitr-graphics.Rnw ](https://github.com/yihui/knitr/blob/master/R/engine.R#L348) and [quarto-d2/\_extensions/d2/d2.lua](https://github.com/data-intuitive/quarto-d2/blob/main/_extensions/d2/d2.lua).
