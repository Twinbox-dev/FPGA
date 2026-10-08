"""Regenerate the 512-point signed Q1.15 cosine/sine ROM for the DFT core."""
import math
from pathlib import Path


OUT = Path(__file__).resolve().parents[1] / "board/user_source/hdl_source/SD/spectrum_twiddle_512.mem"


def signed16(value: float) -> int:
    return round(32767 * value) & 0xFFFF


def main() -> None:
    words = []
    for fn in (math.cos, math.sin):
        for phase in range(512):
            angle = 2 * math.pi * phase / 512
            words.append(f"{signed16(fn(angle)):04X}")
    OUT.write_text("\n".join(words) + "\n", encoding="ascii", newline="\n")
    print(f"wrote {len(words)} coefficients to {OUT}")


if __name__ == "__main__":
    main()
