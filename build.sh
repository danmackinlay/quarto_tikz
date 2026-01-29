#!/usr/local/bin/bash
#rm -rf index_files
#rm -rf docs
#rm -rf tikz-tex
quarto render --profile makepdf
quarto render --profile makehtml
cp pdf_out_dir/TikZ-Example.pdf docs/

