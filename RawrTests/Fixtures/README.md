`sensor.dng` is a synthetic, uncompressed DNG 1.4 generated for these tests by
`python3 generate.py` using only Python standard-library TIFF serialization.
It contains a 16×12 RGB thumbnail at IFD0 and a 256×256 RGGB sensor SubIFD.
No photograph, camera data, NegPy code, or third-party fixture is included.
The generator and fixture are dedicated to the public domain under CC0-1.0.

The sensor is at least 256 pixels on each edge because the Apple decoder rejects
smaller synthetic sensor images. The decoder-identity guard rejects that fallback.
