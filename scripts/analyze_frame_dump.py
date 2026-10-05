#!/usr/bin/env python3
"""Compare a board write/read dump with a 24-bit BMP at RGB565 word granularity.

Examples:
  python scripts/analyze_frame_dump.py --bmp img/golden/IMG4.BMP \
      --wr img/capture_wr.bin --rb img/capture_rb.bin
  python scripts/analyze_frame_dump.py --bmp img/golden/IMG4.BMP \
      --url http://127.0.0.1:5000 --save-dir img/golden

The readback stream contains every third 32-bit display word. The comparison
uses display-memory addresses; it never treats the sparse stream as contiguous
image rows. A selected BMP must be the image shown by the captured frame.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from urllib.request import urlopen


FRAME_WORDS = 460800
WORDS_PER_ROW = 640


def words_from_bytes(data: bytes) -> list[int]:
    if len(data) % 4:
        raise ValueError('dump length is not a multiple of four bytes')
    return [word[0] for word in struct.iter_unpack('<I', data)]


def pack565(b: int, g: int, r: int) -> int:
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)


def expected_from_bmp(path: Path):
    data = path.read_bytes()
    if data[:2] != b'BM':
        raise ValueError('source is not a BMP')
    pixel_offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18)
    bpp = struct.unpack_from('<H', data, 28)[0]
    compression = struct.unpack_from('<I', data, 30)[0]
    if not (1 <= width <= 1280 and 1 <= height <= 720 and
            bpp == 24 and compression == 0):
        raise ValueError('expected a bottom-up, uncompressed 24-bit BMP within 720p')
    row_bytes = (width * 3 + 3) & ~3
    if len(data) < pixel_offset + row_bytes * height:
        raise ValueError('BMP pixel data is truncated')

    x0, y0 = (1280 - width) // 2, (720 - height) // 2
    written_words = []
    display_words = [0] * FRAME_WORDS
    for file_row in range(height):
        line = [0] * 1280
        row_offset = pixel_offset + file_row * row_bytes
        for x in range(width):
            p = row_offset + x * 3
            line[x0 + x] = pack565(*data[p:p + 3])
        packed = [line[x] | (line[x + 1] << 16) for x in range(0, 1280, 2)]
        written_words.extend(packed)
        display_row = y0 + height - 1 - file_row
        display_words[display_row * WORDS_PER_ROW:(display_row + 1) * WORDS_PER_ROW] = packed
    return written_words, display_words, (x0, y0, width, height)


def in_image(word_index: int, box) -> bool:
    x0, y0, width, height = box
    row, col = divmod(word_index, WORDS_PER_ROW)
    return y0 <= row < y0 + height and 2 * col + 1 >= x0 and 2 * col < x0 + width


def compare(bmp: Path, wr_data: bytes, rb_data: bytes, stride: int,
            previous_rb: bytes | None = None,
            write_port_addresses: bool = False,
            read_port_addresses: bool = False):
    written, display, box = expected_from_bmp(bmp)
    wr, rb = words_from_bytes(wr_data), words_from_bytes(rb_data)
    if stride < 1:
        raise ValueError('readback stride must be positive')

    wr_compared = min(len(wr), len(written))
    wr_exact = sum(a == b for a, b in zip(wr[:wr_compared], written))
    if read_port_addresses:
        base_results = []
        for base in (0, 460800):
            offsets = {d: 0 for d in range(-8, 9)}
            for j, address in enumerate(rb):
                expected_address = base + stride * j
                if expected_address >= base + FRAME_WORDS:
                    break
                for d in offsets:
                    offsets[d] += address == expected_address + d
            base_results.append((base, offsets[0], offsets))
        base, addr_exact, addr_offsets = max(base_results, key=lambda item: item[1])
        return {
            'bmp': str(bmp), 'image_size': list(box[2:]),
            'probe': 'SDRAM application read request addresses',
            'write_words': len(wr), 'write_compared': wr_compared,
            'write_exact': wr_exact,
            'write_matches_bmp': len(wr) == len(written) and wr_exact == len(written),
            'read_address_sample_words': len(rb), 'read_address_stride': stride,
            'read_buffer_base': base, 'read_address_exact': addr_exact,
            'read_address_top_offsets': [
                {'words': d, 'matches': n} for d, n in sorted(
                    addr_offsets.items(), key=lambda item: item[1], reverse=True)[:6]],
            'write_sha256': hashlib.sha256(wr_data).hexdigest(),
            'read_address_sha256': hashlib.sha256(rb_data).hexdigest(),
        }
    if write_port_addresses:
        x0, y0, width, height = box
        source_words = height * WORDS_PER_ROW
        base_results = []
        for base in (0, 460800):
            exact = 0
            offsets = {d: 0 for d in range(-8, 9)}
            for j, address in enumerate(rb):
                source_index = stride * j
                if source_index >= source_words:
                    break
                file_row, col = divmod(source_index, WORDS_PER_ROW)
                expected_address = base + (y0 + height - 1 - file_row) * WORDS_PER_ROW + col
                exact += address == expected_address
                for d in offsets:
                    offsets[d] += address == expected_address + d
            base_results.append((base, exact, offsets))
        base, addr_exact, addr_offsets = max(base_results, key=lambda item: item[1])
        return {
            'bmp': str(bmp), 'image_size': list(box[2:]),
            'probe': 'SDRAM application write port',
            'write_words': len(wr), 'write_compared': wr_compared,
            'write_exact': wr_exact,
            'write_matches_bmp': len(wr) == len(written) and wr_exact == len(written),
            'address_sample_words': len(rb), 'address_stride': stride,
            'write_buffer_base': base, 'address_exact': addr_exact,
            'address_top_offsets': [
                {'words': d, 'matches': n} for d, n in sorted(
                    addr_offsets.items(), key=lambda item: item[1], reverse=True)[:6]],
            'write_sha256': hashlib.sha256(wr_data).hexdigest(),
            'address_sha256': hashlib.sha256(rb_data).hexdigest(),
        }
    active = [(j, stride * j) for j in range(len(rb))
              if stride * j < FRAME_WORDS and in_image(stride * j, box)]
    offsets = {}
    for offset in range(-8, 9):
        offsets[offset] = sum(
            rb[j] == display[i + offset] for j, i in active
            if 0 <= i + offset < FRAME_WORDS)
    top_offsets = sorted(offsets.items(), key=lambda pair: pair[1], reverse=True)[:6]
    match_top_two = sum(
        rb[j] == display[i + top_offsets[0][0]] or
        rb[j] == display[i + top_offsets[1][0]]
        for j, i in active
        if 0 <= i + top_offsets[0][0] < FRAME_WORDS and
           0 <= i + top_offsets[1][0] < FRAME_WORDS)
    changed = None
    if previous_rb is not None:
        previous = words_from_bytes(previous_rb)
        changed = sum(a != b for a, b in zip(previous, rb))

    return {
        'bmp': str(bmp), 'image_size': list(box[2:]),
        'write_words': len(wr), 'write_compared': wr_compared,
        'write_exact': wr_exact,
        'write_matches_bmp': len(wr) == len(written) and wr_exact == len(written),
        'read_words': len(rb), 'read_stride': stride,
        'image_sample_words': len(active),
        'read_exact_at_address': offsets[0],
        'best_offsets': [{'words': d, 'matches': n} for d, n in top_offsets],
        'matches_at_best_two_offsets': match_top_two,
        'changed_words_vs_previous': changed,
        'write_sha256': hashlib.sha256(wr_data).hexdigest(),
        'read_sha256': hashlib.sha256(rb_data).hexdigest(),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--bmp', type=Path, required=True)
    ap.add_argument('--wr', type=Path)
    ap.add_argument('--rb', type=Path)
    ap.add_argument('--stride', type=int, default=3)
    ap.add_argument('--url', help='existing local Web console, e.g. http://127.0.0.1:5000')
    ap.add_argument('--save-dir', type=Path)
    ap.add_argument('--previous-rb', type=Path)
    ap.add_argument('--write-port-addresses', action='store_true',
                    help='type 3 holds App_wr_din; type 4 holds every third App_wr_addr')
    ap.add_argument('--read-port-addresses', action='store_true',
                    help='type 4 holds every third App_rd_addr after a D trigger')
    args = ap.parse_args()

    if args.url:
        dumps = {}
        headers = {}
        for slot in ('wr', 'rb'):
            with urlopen(args.url.rstrip('/') + '/api/frame?slot=' + slot, timeout=5) as response:
                dumps[slot] = response.read()
                headers[slot] = dict(response.headers.items())
        stride = int(headers['rb'].get('X-Frame-Stride', args.stride))
        if args.save_dir:
            args.save_dir.mkdir(parents=True, exist_ok=True)
            for slot in ('wr', 'rb'):
                (args.save_dir / ('capture_' + slot + '.bin')).write_bytes(dumps[slot])
    else:
        if not args.wr or not args.rb:
            ap.error('provide both --wr and --rb, or use --url')
        dumps = {'wr': args.wr.read_bytes(), 'rb': args.rb.read_bytes()}
        headers = None
        stride = args.stride

    result = compare(args.bmp, dumps['wr'], dumps['rb'], stride,
                     args.previous_rb.read_bytes() if args.previous_rb else None,
                     args.write_port_addresses, args.read_port_addresses)
    if headers:
        result['frame_headers'] = {
            slot: {k: v for k, v in h.items() if k.lower().startswith('x-frame')}
            for slot, h in headers.items()}
        result['same_frame_timestamp'] = (
            headers['wr'].get('X-Frame-Ts') == headers['rb'].get('X-Frame-Ts'))
    if not result['write_matches_bmp']:
        result['warning'] = 'write stream differs from selected BMP; verify image identity before interpreting read offsets'
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
