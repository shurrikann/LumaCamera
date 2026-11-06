#!/usr/bin/env python3
"""Convert a 512px sRGB tiled PNG to a 64-cube Xcode data asset. Requires Pillow.
Usage: python3 Scripts/convert_tiled_lut.py Docs/Filter-References/m9.png LumaCamera/Resources/Assets.xcassets/FilmLUT-M9.dataset
"""
import argparse
import array
import hashlib
import json
from pathlib import Path
import sys
from PIL import Image


def convert(source: Path, destination: Path) -> None:
    with Image.open(source) as original:
        if original.format != 'PNG' or original.size != (512, 512):
            raise ValueError('Expected an unscaled 512x512 PNG, containing 8x8 tiles of 64x64 pixels')
        image = original.convert('RGBA')
    pixels = image.load()
    values = array.array('f')
    for blue in range(64):
        for green in range(64):
            for red in range(64):
                rgba = pixels[(blue % 8) * 64 + red, (blue // 8) * 64 + green]
                if rgba[3] != 255:
                    raise ValueError('LUT reference must be opaque')
                values.extend([component / 255 for component in rgba[:3]] + [1.0])
    if values.itemsize != 4:
        raise ValueError('Platform Float32 representation unavailable')
    if sys.byteorder != 'little':
        values.byteswap()
    destination.mkdir(parents=True, exist_ok=True)
    filename = 'M9.rgba32f'
    (destination / filename).write_bytes(values.tobytes())
    (destination / 'Contents.json').write_text(json.dumps({
        'data': [{'filename': filename, 'idiom': 'universal'}],
        'info': {'author': 'xcode', 'version': 1}
    }, indent=2) + '\n')
    print('Source SHA256:', hashlib.sha256(source.read_bytes()).hexdigest())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    convert(args.source, args.destination)
