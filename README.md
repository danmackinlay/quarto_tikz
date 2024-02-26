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

````qmd
```{.tikz embed_mode="link" scale=3 filename="example" format="svg"}
\node[draw, circle] (A) at (0,0) {A};
\node[draw, circle] (B) at (2,2) {B};
\node[draw, circle] (C) at (4,0) {C};
\node[draw, circle] (seven) at (5,1) {888888};
\draw[->] (A) -- (B);
\draw[->] (B) -- (C);
\draw[->] (C) -- (A);
```
````
This should appear in the output as an image

![](./images/example-1.svg)

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).

## Render failures

Note that _if ghostscript libraries are not discoverable on your system [we will fail to render SVGs correctly](https://dvisvgm.de/FAQ/)_.
Getting ghostscript installed appropriately can be fiddly on MacOS;
On recent macs [it should be sufficient to install MacTex 2023](https://tex.stackexchange.com/a/663229) with the _install ghostscript dynamic library_ option checked.
Before macTeX 2023 there are workarounds involving setting the ghostscript library path.
For example if I have Apple Silicon and homebrew ghostscript installed, I can set the following environment variables:

```bash
export LIBGS=/opt/homebrew/lib/libgs.dylib
```

## PDF output

This does produce PDFs which can be included in PDF output; I wonder if we could shortcut the PDF rendering and just output as plain LaTeX in that case to integrate into the main LaTeX rendering workflow?
I’m not suite sure how to handle the TikZ libraries in that case.

Pull requests welcome.

## Efficiency

This filter is not particularly efficient, as it has no execution caching;
A better implementation would include a whole tikz language engine.
That feels like a lot more work than I can justify for the current project.

Not that `dvisvgm` supports a cache via the `--cache` option, and that latex can be fairly good at caching if we allow the intermediate files to persist; maybe we could even exploit quarto infrastructure to do so?

Pull requests for that issue also welcome.

## Credits

Created by cribbing the tricks from [knitr/inst/examples/knitr-graphics.Rnw ](https://github.com/yihui/knitr/blob/master/R/engine.R#L348) and [quarto-d2/\_extensions/d2/d2.lua](https://github.com/data-intuitive/quarto-d2/blob/main/_extensions/d2/d2.lua).
