"""Export the existing approved squirrel mask; no replacement artwork.

Run from any directory with Python + Pillow. Only Android resource files are
written. Colors and mask conversion match the Flutter/Windows brand assets.
"""
from pathlib import Path
from PIL import Image

android = Path(__file__).resolve().parents[1]
app = android.parent
resources = android / "app/src/main/res"
mask = Image.open(app / "assets/images/squirrel-mask.png").convert("RGB")
alpha = mask.getchannel("R").point(lambda red: max(0, min(255, round(red * 1.04 - 5))))
alpha = alpha.crop(alpha.getbbox())
amber = (255, 189, 81)
background = (18, 21, 22, 255)


def squirrel(canvas_size: int, drawing_size: int, color: tuple[int, ...]) -> Image.Image:
    drawing = alpha.copy()
    drawing.thumbnail((drawing_size, drawing_size), Image.Resampling.LANCZOS)
    glyph = Image.new("RGBA", drawing.size, color + (0,))
    glyph.putalpha(drawing)
    canvas = Image.new("RGBA", (canvas_size, canvas_size))
    canvas.alpha_composite(glyph, ((canvas_size - glyph.width) // 2, (canvas_size - glyph.height) // 2))
    return canvas


for density, scale in (("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)):
    directory = resources / f"mipmap-{density}"
    directory.mkdir(parents=True, exist_ok=True)
    legacy_size = round(48 * scale)
    legacy = Image.new("RGBA", (legacy_size, legacy_size), background)
    legacy.alpha_composite(squirrel(legacy_size, round(34 * scale), amber))
    legacy.save(directory / "ic_launcher.png", optimize=True)
    legacy.save(directory / "ic_launcher_round.png", optimize=True)
    # Entire mark stays inside the 66dp adaptive mask safe zone.
    squirrel(round(108 * scale), round(60 * scale), amber).save(directory / "ic_launcher_foreground.png", optimize=True)
    squirrel(round(108 * scale), round(60 * scale), (255, 255, 255)).save(directory / "ic_launcher_monochrome.png", optimize=True)
    notification_directory = resources / f"drawable-{density}"
    notification_directory.mkdir(parents=True, exist_ok=True)
    squirrel(round(24 * scale), round(22 * scale), (255, 255, 255)).save(notification_directory / "ic_stat_vpn.png", optimize=True)

print("Exported approved ExVPN squirrel: legacy, adaptive, round, themed and notification icons.")
