import pymupdf
import sys

pdf_file = sys.argv[1]
svg_file = sys.argv[2]
scale = sys.argv[3]

doc = pymupdf.open(pdf_file)
page = doc[0]
#pix = page.get_pixmap(dpi=300)
#pix.save(svg_file, format="SVG")  # store image as a PNG

## Convert page to SVG
#svg_content = page.get_svg_image()
#svg_content = page.get_svg_image(matrix=pymupdf.Identity)
svg_content = page.get_svg_image(matrix=pymupdf.Matrix(scale, scale))

# Save to file
with open(svg_file, "w", encoding="utf-8") as f:
    f.write(svg_content)

doc.close()

