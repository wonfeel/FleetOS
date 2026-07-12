# Builds cc-terminal.{ttf,woff} from the real CC:Tweaked glyph atlas
# (termFont.png, 16x16 grid of 6x9px glyphs), with Cyrillic bolted on since
# the game font never had it. Two sources per Cyrillic letter: "reuse" just
# borrows the exact pixel data of a visually-identical Latin glyph (А=A,
# а=a - real shape, different codepoint), "custom" is hand-drawn 6x9
# bitmaps matched to the real font's baseline (checked against 'A'/'a'/
# 'g'/'y' directly from the atlas).
#
# Needs reference/ (gitignored CC:Tweaked source, see docs/README.html) and
# `pip install numpy pillow fonttools`. Run, then re-embed the woff as
# base64 in dashboard.html's @font-face - not automated, copy-paste it by hand.
import os
import numpy as np
from PIL import Image
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))  # windows/fonts -> windows -> repo root
SRC = os.path.join(REPO_ROOT, "reference", "ComputerCraft-1.79", "src", "main", "resources",
                    "assets", "computercraft", "textures", "gui", "termFont.png")
OUT_TTF = os.path.join(SCRIPT_DIR, "cc-terminal.ttf")
OUT_WOFF = os.path.join(SCRIPT_DIR, "cc-terminal.woff")

FONT_W, FONT_H = 6, 9
UPM = 900
PX = UPM // FONT_H

im = Image.open(SRC).convert("RGBA")
atlas = np.array(im.crop((0, 0, 16 * FONT_W, 16 * FONT_H)))[:, :, 3]


def atlas_glyph_bits(code):
    col = code % 16
    row = code // 16
    sub = atlas[row * FONT_H:(row + 1) * FONT_H, col * FONT_W:(col + 1) * FONT_W]
    return [["#" if v > 128 else "." for v in r] for r in sub]


def rows_to_bits(rows):
    # rows: list of up to 9 strings, each up to 6 chars ('#'/'.'), given in
    # a dict keyed by the row index they occupy (0=top .. 8=bottom) so
    # callers only have to write the rows that actually contain ink.
    grid = [["."] * FONT_W for _ in range(FONT_H)]
    for y, s in rows.items():
        for x, c in enumerate(s):
            grid[y][x] = c
    return grid


# ---- direct reuse: same shape as an existing Latin letter in the real atlas
REUSE = {
    "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
    "Р": "P", "С": "C", "Т": "T", "Х": "X",
    "а": "a", "е": "e", "к": "k", "м": "m", "о": "o", "р": "p", "с": "c",
    "у": "y", "х": "x", "н": "n",
}

# ---- hand-drawn custom glyphs, keyed by row index -> 6-char string
CUSTOM = {
    "Б": {
    0: ".####.", 
    1: "#.....", 
    2: "#.....", 
    3: "#####.", 
    4: "#....#", 
    5: "#....#", 
    6: ".####."},
    
    "Г": {
    0: "######", 
    1: "#.....", 
    2: "#.....", 
    3: "#.....", 
    4: "#.....", 
    5: "#.....", 
    6: "#....."},
    
    "Д": {
    0: ".####.", 
    1: "#....#", 
    2: "#....#", 
    3: "#....#", 
    4: "#....#", 
    5: "######", 
    6: "#....#"},
    
    "Ж": {
    0: "#.#.#.", 
    1: ".###..", 
    2: "..#...", 
    3: ".###..", 
    4: "#.#.#.", 
    5: "#.#.#.", 
    6: "#.#.#."},
    
    "З": {
    0: ".####.", 
    1: "#....#", 
    2: ".....#", 
    3: "..###.", 
    4: ".....#", 
    5: "#....#", 
    6: ".####."},
    
    "И": {
    0: "#....#", 
    1: "#....#", 
    2: "#...##", 
    3: "#..#.#", 
    4: "#.#..#", 
    5: "##...#", 
    6: "#....#"},
    
    "Й": {
    0: ".#..#.", 
    1: "#....#", 
    2: "#....#", 
    3: "#...##", 
    4: "#..#.#", 
    5: "#.#..#", 
    6: "##...#"},
    
    "Л": {
    0: "..##..", 
    1: ".#..#.", 
    2: ".#..#.", 
    3: "#....#", 
    4: "#....#", 
    5: "#....#", 
    6: "#....#"},
    
    "П": {
    0: "######", 
    1: "#....#", 
    2: "#....#", 
    3: "#....#", 
    4: "#....#", 
    5: "#....#", 
    6: "#....#"},
    
    "У": {
    0: "#....#", 
    1: "#....#", 
    2: ".#..#.", 
    3: "..##..", 
    4: "..#...", 
    5: "..#...", 
    6: ".##..."},
    
    "Ф": {
    0: "..#...", 
    1: ".###..", 
    2: "#.#.#.", 
    3: "#.#.#.", 
    4: ".###..", 
    5: "..#...", 
    6: "..#..."},
    
    "Ц": {
    0: "#....#", 
    1: "#....#", 
    2: "#....#", 
    3: "#....#", 
    4: "#....#", 
    5: "######", 
    6: ".....#"},
    
    "Ч": {
    0: "#...#.", 
    1: "#...#.", 
    2: "#...#.", 
    3: ".####.", 
    4: ".....#", 
    5: ".....#", 
    6: ".....#"},
    
    "Ш": {
    0: "#.#.#.", 
    1: "#.#.#.", 
    2: "#.#.#.", 
    3: "#.#.#.", 
    4: "#.#.#.", 
    5: "#.#.#.", 
    6: "######"},
    
    "Щ": {
    0: "#.#.#.", 
    1: "#.#.#.", 
    2: "#.#.#.", 
    3: "#.#.#.", 
    4: "#.#.#.", 
    5: "#.#.#.", 
    6: "######", 
    7: ".....#"},
    
    "Ъ": {
    0: "###...", 
    1: "..#...", 
    2: "..#.#.", 
    3: "..###.", 
    4: "..#..#", 
    5: "..#..#", 
    6: "..###."},
    
    "Ы": {
    0: "#..#..", 
    1: "#..#..", 
    2: "#..#..", 
    3: "#..#..", 
    4: "#.###.", 
    5: "#.#..#", 
    6: "#.###."},
    
    "Ь": {
    0: "#.....", 
    1: "#.....", 
    2: "#.....", 
    3: "#.....", 
    4: "#.###.", 
    5: "#.#..#", 
    6: "#.###."},
    
    "Э": {
    0: ".####.", 
    1: "#....#", 
    2: "....#.", 
    3: "..###.", 
    4: "....#.", 
    5: "#....#", 
    6: ".####."},
    
    "Ю": {
    0: "#..##.", 
    1: "#.#..#", 
    2: "#.#..#", 
    3: "###..#", 
    4: "#.#..#", 
    5: "#.#..#", 
    6: "#..##."},
    
    "Я": {
    0: ".####.", 
    1: "#....#", 
    2: "#....#", 
    3: ".####.", 
    4: "#..#..", 
    5: "#...#.", 
    6: "#....#"},
    
    "Ё": {
    0: ".#.#..", 
    1: "######", 
    2: "#.....", 
    3: "#####.", 
    4: "#.....", 
    5: "#.....", 
    6: "######"},

    "б": {
    2: ".####.", 
    3: "#.....", 
    4: "#####.", 
    5: "#....#", 
    6: ".####."},
    
    "в": {
    2: "####..", 
    3: "#...#.", 
    4: "####..", 
    5: "#...#.", 
    6: "####.."},
    
    "г": {
    2: "#####.", 
    3: "#.....", 
    4: "#.....", 
    5: "#.....", 
    6: "#....."},
    
    "д": {
    2: ".####.", 
    3: "#....#", 
    4: "#....#", 
    5: "######", 
    6: "#....#"},
    
    "ж": {
    2: "#.#.#.", 
    3: ".###..", 
    4: "..#...", 
    5: ".###..", 
    6: "#.#.#."},
    
    "з": {
    2: ".####.", 
    3: ".....#", 
    4: "..###.", 
    5: ".....#", 
    6: ".####."},
    
    "и": {
    2: "#....#", 
    3: "#...##", 
    4: "#..#.#", 
    5: "#.#..#", 
    6: "##...#"},
    
    "й": {
    1: ".#..#.", 
    2: "#....#", 
    3: "#...##", 
    4: "#..#.#", 
    5: "#.#..#", 
    6: "##...#"},
    
    "л": {
    2: "..##..", 
    3: ".#..#.", 
    4: "#....#", 
    5: "#....#", 
    6: "#....#"},
    
    "п": {
    2: "######", 
    3: "#....#", 
    4: "#....#", 
    5: "#....#", 
    6: "#....#"},
    
    "т": {
    2: "######", 
    3: "..#...", 
    4: "..#...", 
    5: "..#...", 
    6: "..#..."},
    
    "ф": {
    1: "..#...", 
    2: ".###..", 
    3: "#.#.#.", 
    4: "#.#.#.", 
    5: ".###..", 
    6: "..#...", 
    7: "..#..."},
    
    "ц": {
    2: "#....#", 
    3: "#....#", 
    4: "#....#", 
    5: "######", 
    6: ".....#", 
    7: ".....#"},
    
    "ч": {
    2: "#...#.", 
    3: "#...#.", 
    4: ".####.", 
    5: ".....#", 
    6: ".....#"},
    
    "ш": {
    2: "#.#.#.", 
    3: "#.#.#.", 
    4: "#.#.#.", 
    5: "#.#.#.", 
    6: "######"},
    
    "щ": {
    2: "#.#.#.", 
    3: "#.#.#.", 
    4: "#.#.#.", 
    5: "#.#.#.", 
    6: "######", 
    7: ".....#"},
    
    "ъ": {
    2: "##....", 
    3: "..#...", 
    4: "..###.", 
    5: "..#..#", 
    6: "..###."},
    
    "ы": {
    2: "#..#..", 
    3: "#..#..", 
    4: "#.###.", 
    5: "#.#..#", 
    6: "#.###."},
    
    "ь": {
    2: "#.....", 
    3: "#.....", 
    4: "#.###.", 
    5: "#.#..#", 
    6: "#.###."},
    
    "э": {
    2: ".####.", 
    3: "#....#", 
    4: "..###.", 
    5: "#....#", 
    6: ".####."},
    
    "ю": {
    2: "#.##..", 
    3: "#.#.#.", 
    4: "###.#.", 
    5: "#.#.#.", 
    6: "#.##.."},
    
    "я": {
    2: ".####.", 
    3: "#....#", 
    4: ".####.", 
    5: "#..#..", 
    6: "#...#."},
    
    "ё": {
    1: ".#.#..", 
    2: ".####.", 
    3: "#.....", 
    4: "#####.", 
    5: "#....#", 
    6: ".####."},
}

glyph_order = [".notdef"]
char_to_glyph = {}
for code in range(256):
    name = f"g{code:03d}"
    glyph_order.append(name)
    char_to_glyph[code] = name

# reserve names for cyrillic codepoints
cyr_letters = list(REUSE.keys()) + list(CUSTOM.keys())
for ch in cyr_letters:
    name = f"u{ord(ch):04x}"
    glyph_order.append(name)
    char_to_glyph[ord(ch)] = name

glyphs = {}
advance = FONT_W * PX


def build_glyph_from_bits(bits):
    pen = TTGlyphPen(None)
    has_contour = False
    for y in range(FONT_H):
        for x in range(FONT_W):
            if bits[y][x] != "#":
                continue
            has_contour = True
            x0 = x * PX
            x1 = x0 + PX
            y1 = (FONT_H - y) * PX
            y0 = y1 - PX
            pen.moveTo((x0, y0))
            pen.lineTo((x1, y0))
            pen.lineTo((x1, y1))
            pen.lineTo((x0, y1))
            pen.closePath()
    if not has_contour:
        pen.moveTo((0, 0))
        pen.closePath()
    return pen.glyph()


glyphs[".notdef"] = build_glyph_from_bits(atlas_glyph_bits(0))
for code in range(256):
    glyphs[char_to_glyph[code]] = build_glyph_from_bits(atlas_glyph_bits(code))

for ch, latin in REUSE.items():
    glyphs[char_to_glyph[ord(ch)]] = build_glyph_from_bits(atlas_glyph_bits(ord(latin)))

for ch, rows in CUSTOM.items():
    glyphs[char_to_glyph[ord(ch)]] = build_glyph_from_bits(rows_to_bits(rows))

fb = FontBuilder(UPM, isTTF=True)
fb.setupGlyphOrder(glyph_order)
cmap = {code: char_to_glyph[code] for code in range(32, 256)}
cmap.update({ord(ch): char_to_glyph[ord(ch)] for ch in cyr_letters})
fb.setupCharacterMap(cmap)
fb.setupGlyf(glyphs)
metrics = {name: (advance, 0) for name in glyph_order}
fb.setupHorizontalMetrics(metrics)
fb.setupHorizontalHeader(ascent=UPM, descent=0)
fb.setupNameTable({"familyName": "CC Terminal", "styleName": "Regular"})
fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, usWinAscent=UPM, usWinDescent=0)
fb.setupPost()

import os
os.makedirs(os.path.dirname(OUT_TTF), exist_ok=True)
fb.save(OUT_TTF)
print("saved", OUT_TTF, "- glyphs:", len(glyph_order))

fb2 = TTFont = None
from fontTools.ttLib import TTFont as _TTFont
f2 = _TTFont(OUT_TTF)
f2.flavor = "woff"
f2.save(OUT_WOFF)
print("saved", OUT_WOFF)
