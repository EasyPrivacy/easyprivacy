#!/usr/bin/env python3
"""Export Android notification masks from the existing EasyPrivacy logo.

Unlike launcher icons, Android status icons use a white alpha mask without a
background. Re-export with Python 3 and Pillow when the source mark changes.
"""

from pathlib import Path
import argparse

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--app", choices=["core", "vpn", "files"], default="vpn")
APP = ROOT / "apps" / parser.parse_args().app
SOURCE = ROOT / "assets/EasyPrivacy_Transparant_Black.png"
RES = APP / "android/app/src/main/res"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def main():
    source = Image.open(SOURCE).convert("RGBA")
    alpha = source.getchannel("A")
    bounds = alpha.point(lambda a: 255 if a > 127 else 0).getbbox()
    if bounds is None:
        raise ValueError("The EasyPrivacy source mark has no visible pixels")
    alpha = alpha.crop(bounds)
    for density, scale in DENSITIES.items():
        size = round(24 * scale)
        mask = alpha.copy()
        mask.thumbnail((round(22 * scale), round(22 * scale)), Image.Resampling.LANCZOS)
        canvas = Image.new("L", (size, size), 0)
        canvas.paste(mask, ((size - mask.width) // 2, (size - mask.height) // 2))
        icon = Image.new("RGBA", (size, size), (255, 255, 255, 0))
        icon.putalpha(canvas)
        destination = RES / f"drawable-{density}/ic_vpn_status.png"
        destination.parent.mkdir(parents=True, exist_ok=True)
        icon.save(destination)
    print("Exported EasyPrivacy notification masks at all Android densities.")


if __name__ == "__main__":
    main()
