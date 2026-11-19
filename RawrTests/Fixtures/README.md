`sensor.dng` is a synthetic, uncompressed DNG 1.4 generated for these tests by
`python3 generate.py` using only Python standard-library TIFF serialization.
It contains a 16×12 RGB thumbnail at IFD0 and a 256×256 RGGB sensor SubIFD.
No photograph, camera data, NegPy code, or third-party fixture is included.
The generator and fixture are dedicated to the public domain under CC0-1.0.

`RealScanRegressionTests.swift` also generates four-plane LinearRaw DNGs at
runtime, with explicit reduction/colour matrices, variable fourth-plane samples,
black levels, rotation, and malformed-storage cases. Its oversized fixture
extends this synthetic sensor to 129 MP with generated gradient rows; decoding
must allocate a bounded working preview and reject a full-resolution request.
No large binary fixture or photograph is checked in. Scanner-like narrow clear
strips, black holders, textured edges and grain are generated in
`NegativeMeteringTests.swift`.

The sensor is at least 256 pixels on each edge because the Apple decoder rejects
smaller synthetic sensor images. The decoder-identity guard rejects that fallback.

Run the unhosted unit target with the `RawrTests` scheme. It also records a
headless PNG of the production preview pane contents as a test attachment.

The optional Nikon regression uses the original NASA NEF from
[rawpy's pinned test data](https://github.com/letmaik/rawpy/blob/2705f5b223c162c3cbc48474fe1a01c3cf09fa4f/test/iss030e122639.NEF).
SHA-256: `5922721d13f11795557d97fdeb0a60b900086c402bc82a848ff280d15b99ffd4`.
Set `RAWR_NEF_FIXTURE` in the test process environment to its local file path.
It verifies anonymous ImageIO's 160×120 preview, typed RAW Data and URL decoding,
graph preview, and a 4256×2832 TIFF export. This 10 MB external file is not bundled.
