"""Generate sensor.dng using only Python stdlib; no camera image or third-party code.
A DNG 1.4 TIFF with 16x12 RGB IFD0 and a 256x256 uncompressed RGGB SubIFD.
"""
import struct
from pathlib import Path

pack = lambda fmt, *v: struct.pack("<" + fmt, *v)
blob = bytearray(b"II" + pack("HI", 42, 8))

def ifd(entries):
    entries = sorted(entries)
    offset = len(blob)
    blob.extend(bytes(2 + 12 * len(entries) + 4))
    struct.pack_into("<H", blob, offset, len(entries))
    patches = {}
    for i, (tag, kind, count, value) in enumerate(entries):
        location = offset + 2 + i * 12
        struct.pack_into("<HHI", blob, location, tag, kind, count)
        if value is None:
            patches[tag] = location + 8
        elif len(value) <= 4:
            blob[location + 8:location + 8 + len(value)] = value
        else:
            struct.pack_into("<I", blob, location + 8, len(blob))
            blob.extend(value)
            if len(blob) % 2:
                blob.append(0)
    return offset, patches

def short(tag, *v): return tag, 3, len(v), pack("H" * len(v), *v)
def long(tag, value=None): return tag, 4, 1, None if value is None else pack("I", value)
def rational(tag, *v): return tag, 5, len(v), b"".join(pack("II", n, d) for n, d in v)
def text(tag, value): return tag, 2, len(value) + 1, value.encode() + b"\0"

_, preview = ifd([
    long(254, 1), long(256, 16), long(257, 12), short(258, 8, 8, 8),
    short(259, 1), short(262, 2), long(273), short(277, 3), long(278, 12),
    long(279, 16 * 12 * 3), short(284, 1), long(330),
    text(271, "Rawr Tests"), text(272, "Synthetic Sensor"),
    (50706, 1, 4, bytes([1, 4, 0, 0])), (50707, 1, 4, bytes([1, 1, 0, 0])),
    text(50708, "Rawr Synthetic Sensor"),
    (50721, 10, 9, b"".join(pack("ii", n, 10000) for n in [10000, 0, 0, 0, 10000, 0, 0, 0, 10000])),
    rational(50728, (1, 1), (1, 1), (1, 1)), short(50778, 21),
])
sensor_offset, sensor = ifd([
    long(254, 0), long(256, 256), long(257, 256), short(258, 16), short(259, 1),
    short(262, 32803), long(273), short(277, 1), long(278, 256), long(279, 256 * 256 * 2),
    short(284, 1), short(33421, 2, 2), (33422, 1, 4, bytes([0, 1, 1, 2])),
    (50710, 1, 3, bytes([0, 1, 2])), short(50711, 1), short(50713, 1, 1),
    rational(50714, (0, 1)), long(50717, 65535),
    rational(50718, (1, 1), (1, 1)), (50719, 4, 2, pack("II", 0, 0)),
    (50720, 4, 2, pack("II", 256, 256)),
])
struct.pack_into("<I", blob, preview[330], sensor_offset)
struct.pack_into("<I", blob, preview[273], len(blob))
blob.extend(bytes([90, 100, 110]) * (16 * 12))
struct.pack_into("<I", blob, sensor[273], len(blob))
for y in range(256):
    for x in range(256):
        blob.extend(pack("H", 4000 + x * 100 + y * 70))
Path(__file__).with_name("sensor.dng").write_bytes(blob)
