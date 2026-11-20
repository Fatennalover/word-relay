"""Generate OCR silhouettes from the bundled Fredoka font (SIL OFL)."""
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ASSETS = Path(__file__).resolve().parent
FONT = ASSETS.parent.parent / "Resources" / "Fredoka.ttf"
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
SHAPE_WIDTH, SHAPE_HEIGHT = 20, 24


def shape(font, letter):
    canvas = Image.new("L", (128, 128))
    ImageDraw.Draw(canvas).text((64, 64), letter, fill=255, font=font, anchor="mm")
    box = canvas.point(lambda value: 255 if value > 110 else 0).getbbox()
    left, top, right, bottom = box
    w, h = right - left, bottom - top
    samples = bytes(
        canvas.getpixel((left + int((x + .5) * w / SHAPE_WIDTH),
                         top + int((y + .5) * h / SHAPE_HEIGHT))) > 110
        for y in range(SHAPE_HEIGHT)
        for x in range(SHAPE_WIDTH)
    )
    return struct.pack("<Bf", ord(letter), w / h) + samples


records = []
for width in (80, 95, 105, 120):
    for weight in (400, 500, 600, 700):
        font = ImageFont.truetype(str(FONT), 94)
        font.set_variation_by_axes([weight, width])
        records.extend(shape(font, letter) for letter in LETTERS)

(ASSETS / "glyphs.bin").write_bytes(b"WRG1" + struct.pack("<H", len(records)) + b"".join(records))
