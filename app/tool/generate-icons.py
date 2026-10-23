#!/usr/bin/env python3
"""Export checked-in platform icons. Requires Python 3 and Pillow."""

from pathlib import Path
import math

from PIL import Image


APP = Path(__file__).resolve().parents[1]
ASSETS = APP.parent / "assets"
RES = APP / "android/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
ICO_SIZES = [(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)]


def save(image, path, **kwargs):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, **kwargs)


def contain(image, size, background=(0, 0, 0, 0), extent=None):
    result = Image.new("RGBA", (size, size), background)
    scaled = image.copy()
    scaled.thumbnail((extent or size, extent or size), Image.Resampling.LANCZOS)
    result.alpha_composite(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2))
    return result


def mark(filename):
    image = Image.open(ASSETS / filename).convert("RGBA")
    # Ignore stray, almost-transparent pixels when centering the mark.
    bounds = image.getchannel("A").point(lambda a: 255 if a > 127 else 0).getbbox()
    if bounds is None:
        raise ValueError(f"No visible logo in {filename}")
    return image.crop((max(0, bounds[0] - 2), max(0, bounds[1] - 2),
                       min(image.width, bounds[2] + 2), min(image.height, bounds[3] + 2)))


def main():
    paper = Image.open(ASSETS / "EasyPrivacy_White.png").convert("RGBA")
    source = Image.open(ASSETS / "EasyPrivacy_Transparant_Black.png").convert("RGBA")
    # Recolor only RGB: preserve every alpha byte, including the original
    # antialiased edges and all internal transparent cutouts.
    white_variant = Image.new("RGBA", source.size, (255, 255, 255, 0))
    white_variant.putalpha(source.getchannel("A"))
    save(white_variant, ASSETS / "EasyPrivacy_Transparant_White.png")
    black = mark("EasyPrivacy_Transparant_Black.png")
    white = mark("EasyPrivacy_Transparant_White.png")

    for density, scale in DENSITIES.items():
        size = round(48 * scale)
        save(contain(paper, size, "white").convert("RGB"),
             RES / f"mipmap-{density}/ic_launcher.png")

        # Keep the whole mark inside Android's central 66dp safe circle on a
        # 108dp layer, including its corners, regardless of the launcher mask.
        size = round(108 * scale)
        factor = 66 * scale / math.hypot(black.width, black.height)
        scaled = black.resize((round(black.width * factor), round(black.height * factor)),
                              Image.Resampling.LANCZOS)
        save(contain(scaled, size), RES / f"drawable-{density}/ic_launcher_foreground.png")

    resources = APP / "windows/runner/resources"
    save(contain(paper, 256, "white"), resources / "app_icon.ico", sizes=ICO_SIZES)
    for color, image in (("black", black), ("white", white)):
        save(contain(image, 256, extent=240), resources / f"titlebar_{color}.ico", sizes=ICO_SIZES)

    save(contain(paper, 256, "white").convert("RGB"), APP / "linux/icons/easyprivacy.png")
    print("Exported Android, Windows and Linux icons from assets/.")


if __name__ == "__main__":
    main()
