"""Rebuild the site's webfonts (site/fonts/*.woff2) from their variable sources.

Each file is one weight of the family's variable font, trimmed to Google Fonts' "latin" set
plus the arrows block (U+2190-21FF) and the layout features the site uses. Sources, from
github.com/google/fonts (OFL):

  ofl/jetbrainsmono/JetBrainsMono[wght].ttf   Version 2.211
  ofl/spacegrotesk/SpaceGrotesk[wght].ttf     Version 2.000

Usage (needs `pip install "fonttools[woff]" brotli`):

  python3 dev/scripts/site-fonts.py <dir with the two .ttf files> site/fonts
"""

import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

COMMON = (
    "U+000D,U+0020-007E,U+00A0-00FF,U+0131,U+0152-0153,U+02BC,U+02C6,U+02DA,U+02DC,"
    "U+0300-0301,U+0303-0304,U+0308-0309,U+0323,U+2013-2014,U+2018-201A,U+201C-201E,"
    "U+2022,U+2026,U+2032-2033,U+2039-203A,U+2044,U+20AC,U+2122,U+2190-21FF,U+2212,U+2215"
)

FAMILIES = {
    "JetBrainsMono": {
        "source": "JetBrainsMono[wght].ttf",
        "weights": [400, 500],
        "unicodes": COMMON + ",U+0102,U+FEFF",
        "features": ["calt", "ccmp", "frac", "locl", "mark"],
    },
    "SpaceGrotesk": {
        "source": "SpaceGrotesk[wght].ttf",
        "weights": [500, 600, 700],
        "unicodes": COMMON + ",U+02BB,U+2009,U+200B",
        "features": ["ccmp", "dnom", "frac", "kern", "liga", "locl", "mark", "mkmk", "numr", "pnum", "tnum"],
    },
}


def main(src_dir, out_dir):
    for family, spec in FAMILIES.items():
        for weight in spec["weights"]:
            font = instancer.instantiateVariableFont(TTFont(f"{src_dir}/{spec['source']}"), {"wght": weight})

            options = subset.Options()
            options.flavor = "woff2"
            options.layout_features = spec["features"]
            options.name_IDs = ["*"]
            options.glyph_names = True
            options.notdef_outline = True

            subsetter = subset.Subsetter(options)
            subsetter.populate(unicodes=subset.parse_unicodes(spec["unicodes"]))
            subsetter.subset(font)

            path = f"{out_dir}/{family}-{weight}.woff2"
            subset.save_font(font, path, options)
            print(f"wrote {path}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
