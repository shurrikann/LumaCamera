#!/usr/bin/env python3
"""Compile .cube LUTs to lossless-resolution half-float RGB resources."""
from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

MAGIC = b"LCUB"


def parse_cube(path: Path) -> tuple[int, list[tuple[float, float, float]]]:
    dimension = None
    values: list[tuple[float, float, float]] = []
    domain_min = (0.0, 0.0, 0.0)
    domain_max = (1.0, 1.0, 1.0)
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        directive = parts[0].upper()
        if directive == "LUT_3D_SIZE":
            if len(parts) != 2:
                raise ValueError(f"{path.name}: malformed LUT_3D_SIZE")
            dimension = int(parts[1])
        elif directive == "DOMAIN_MIN":
            domain_min = tuple(map(float, parts[1:4]))
        elif directive == "DOMAIN_MAX":
            domain_max = tuple(map(float, parts[1:4]))
        elif directive in {"TITLE", "LUT_1D_SIZE"}:
            if directive == "LUT_1D_SIZE":
                raise ValueError(f"{path.name}: 1D cube is not supported")
        elif len(parts) == 3:
            try:
                rgb = tuple(map(float, parts))
            except ValueError:
                continue
            if not all(math.isfinite(channel) for channel in rgb):
                raise ValueError(f"{path.name}: non-finite channel")
            values.append(rgb)
    if dimension not in (33, 65):
        raise ValueError(f"{path.name}: unsupported cube dimension {dimension}")
    if domain_min != (0.0, 0.0, 0.0) or domain_max != (1.0, 1.0, 1.0):
        raise ValueError(f"{path.name}: non-default domain must be reviewed")
    expected = dimension ** 3
    if len(values) != expected:
        raise ValueError(f"{path.name}: expected {expected} RGB entries, found {len(values)}")
    return dimension, values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Folder containing .cube files")
    parser.add_argument("destination", type=Path, help="Output LogLUTs resource folder")
    args = parser.parse_args()
    files = sorted(args.source.glob("*.cube"), key=lambda item: item.name.casefold())
    if not files:
        raise SystemExit("No .cube files found")
    args.destination.mkdir(parents=True, exist_ok=True)
    total = 0
    for path in files:
        dimension, entries = parse_cube(path)
        output = bytearray(struct.pack("<4sI", MAGIC, dimension))
        for red, green, blue in entries:
            output.extend(struct.pack("<eee", red, green, blue))
        destination = args.destination / (path.stem + ".lutcube")
        destination.write_bytes(output)
        total += len(output)
    print(f"compiled {len(files)} LUTs ({total / 1024 / 1024:.2f} MiB), native dimensions 33/65 retained")


if __name__ == "__main__":
    main()
