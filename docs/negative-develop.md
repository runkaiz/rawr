# Negative Develop

Connect **Image Input → Negative Develop → Preview** (Folder Input also works).
Enter the unexposed film border's **linear sRGB** values as Base R/G/B. These
are numeric calibration values, not the display RGB of a screenshot or an
sRGB color-picker swatch. Set separate low/high density endpoints for each
channel, then exposure, contrast and optional toe/shoulder. Defaults are neutral:
base=(1,1,1), endpoints=(0,2) density units, exposure=0, contrast=1, toe=shoulder=0.
No film-stock LUT is applied. New nodes use the automatic metering described
below; uncheck its controls for the manual calibration described here. Existing Inversion documents
retain their original complement shader and decode path.

## Input and output contract

This node requires a source connection, optionally through [Dust Removal](dust-removal.md) and [Auto Crop](auto-crop.md). Its source is decoded at native
resolution with orientation applied once, then rendered directly by Core Image
into a private `rgba32Float` Metal texture in extended linear sRGB. Tagged TIFF
scanner captures are the precise calibration input; ImageIO/Core Image honor
the embedded profile and transfer curve. Other ImageIO formats are accepted
with their decoded color-space interpretation; untagged files may receive an
ImageIO default interpretation and should be explicitly profiled before use.
The working RGB is **not sensor-native RGB or a physical dye-separation space**.
No crosstalk, light-source, scanner or film-characteristic calibration is claimed.

Camera RAW uses Apple's CIRAWFilter at scale 1 (except the bounded oversized-source preview below) with draft off, exposure and
baseline exposure 0, global/shadow boost 0, local tone map 0, gamut mapping off,
luminance/color noise reduction 0, sharpening 0, and no linearSpaceFilter.
Camera neutral/white balance and Apple's camera-to-working-space transform are
retained. The decoder version and native dimensions are logged. Supported
native-size output is checked in both axis orders, and thumbnail fallbacks
with decoder version `None` are rejected. This follows Apple's published
[linear scene-referred decode guidance](https://developer.apple.com/videos/play/wwdc2021/10160/).
Four-plane uncompressed, chunky, unsigned 16-bit LinearRaw DNGs use their
3×4 ReductionMatrix1 to reduce all four colour planes and their 4×3 ColorMatrix1
to three dimensions before Apple performs the working-space conversion. Per-plane
black/white normalization happens first. An explicitly zero reduction weight
excludes a plane; no plane is display alpha or inferred IR. Orientation, default
crop, white chromaticity/neutral and single-illuminant calibration are retained.
Unsupported compression, planar storage, spatial black levels, dual-illuminant
or extra calibration stages fail with an export instruction. Transparent-black
and opaque-black RAW outputs fail content acceptance, even at correct dimensions.
This adapter follows Adobe's [DNG specification](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html).

Full-resolution processing has a ceiling of **128 MP and 16384 pixels per edge**.
Larger RAWs (up to 1 GP / 65536 per edge) can be opened as an explicitly logged
working preview capped at 24 MP and 8192 per edge. Decode scaling happens before
GPU texture allocation. This preview may differ in fine-grain statistics.
Full-resolution export rejects an oversized original with guidance to export a
smaller calibrated linear DNG/TIFF; it never silently exports the preview.
Four-plane adapter storage currently uses the full-resolution ceiling.

The test DNG characterizes dimensions and the float processing/export path;
it does not establish camera-scanning colorimetry for arbitrary cameras.

All development arithmetic and storage are float32, with Metal fast math
disabled so NaN/Inf checks are meaningful. There is no optional half mode.
Density, normalization and print are fused into one compute dispatch, with no
full-image CPU readback between stages. The source and result textures are
private GPU resources. Command failures propagate as an unsuccessful render.
A CGImage is created only at the display-sized Preview boundary, as unsigned
16-bit linear sRGB with its ICC profile. Export writes the GPU result directly
through a deferred Core Image provider and ImageIO for TIFF, or Core Image's
file writer for PNG/JPEG. Display conversion is performed by the
profile-aware SwiftUI image view. TIFF contains linear positive RGB, not an
sRGB transfer curve; encoding quantization occurs only at the terminal boundary.
Alpha is premultiplied at texture boundaries, and straight RGB is used for logs.

Preview renders the same native-size development as export and then uses
Core Image Lanczos scaling on the positive result. Thus fine structure does not
change meaning through pre-log downsampling. The tradeoff is full-resolution
development cost and memory on each slider edit; unchanged upstream cleanup
and statistics are reused. The compute graph still uses full-size textures;
see [performance](performance.md) for resource bounds and benchmark methodology. There is
an optional Auto Crop node that preserves validated source-border evidence before cropping. Preview and export share the existing serialized request FIFO.

## Equations and finite policy

For each channel c, let I be straight linear input and B the selected base:

```
T = clamp(I / B, 1e-6, 1)
D = -log10(T)
D = (D - balanceOffset[c]) / balanceSlope[c]
x = clamp((D - low[c]) / (high[c] - low[c]), 0, 1)
x = clamp(x * 2^exposureEV, 0, 1)
x = clamp(0.5 + contrast * (x - 0.5), 0, 1)
y = x + x*(1-x) * (shoulder*x - toe*(1-x))
```

Density increases toward positive white: the low density endpoint prints black,
the high endpoint prints white. Manual per-layer normalization is independent. Automatic modes use the
frame statistics described below. Base RGB must lie in [1e-6,16]; each low >= -6,
high <= 6, high-low >= .01. Exposure is [-8,8], contrast [.1,4], toe/shoulder
[0,.5]. Nonfinite or invalid calibration fails explicitly. Missing saved values
migrate to defaults without replacing existing values.

The cubic is an endpoint-preserving Hermite curve with slopes 1-toe and
1-shoulder; for these bounds its derivative is at least .5. Both zero gives
identity, preserving a neutral default. It does not model a particular paper.
Equal normalized channel densities stay equal under every print setting.
NaN, negative values and -Inf input become zero transmission; +Inf saturates
at B; I>B clips to base. Zero/near-zero transmission floors at 1e-6 of B
(maximum relative density 6). This is a declared numerical floor, not a measured
scanner noise estimate. Nonfinite alpha becomes zero; finite alpha clamps to
[0,1]. Fully transparent pixels become transparent black; color is processed
unpremultiplied and then premultiplied for output.

## Validation and provenance

Swift Testing exercises neutral/orange wedges, independent Float64 log/print
reference math, channel endpoints and curve extremes, zero/clipped/NaN/Inf,
alpha, invalid calibration, document migration, native RAW dimensions,
orientation, profile and 16-bit unsigned TIFF export, and folder sources.
Shader/reference absolute error limit is **1e-5 before output encoding**.
Preview/full-res comparison uses Lanczos of the exported positive at the same
scale and allows **4/65535 per linear channel** (terminal quantization and
resampling). Headless view-rendering attachments show the production controls
and Before/After pane contents without launching an app or activating a window.
The negative controls use an offscreen NSHostingView bitmap because native
TextFields cannot be flattened by ImageRenderer.

Implementation and synthetic fixtures were independently written from the
Rawr check-up report's equations and acceptance requirements and Apple's API
documentation. No NegPy source, tests, LUTs, profiles, assets or constants were
opened or copied. The test oracle uses scalar Float64 log/pow and Hermite basis
polynomials, independently of the shader's float factorization.

A real licensed negative with an unexposed border and a color/gray reference
is a separate acceptance artifact; synthetic wedges do not establish physical
color accuracy. See the task validation report for the supplied artifact and
measured results before claiming that part of acceptance.

## Automatic metering (version 3)

New nodes enable **Film base**, **Density endpoints**, and **Neutral balance**
automatically. Existing documents without these switches retain manual behavior.
Each checkbox independently selects the estimate or the saved manual values.
**Lock** copies the displayed estimate into editable document parameters and
turns off that group's automatic switch. Estimates and confidence remain visible
when manual values are active. Exposure/contrast/toe/shoulder remain manual.

Analysis reads the oriented, native-resolution source on Metal at deterministic
stratified cell centers on a grid capped at 512×512. There is no pre-log averaging.
The outer 5% on each edge is a base-candidate region and is excluded from scene
endpoints and neutral fitting. Nonfinite pixels, alpha below .99, and pixels
with any straight channel outside (1e-6, .99999) are excluded. This assumes a
capture saturation ceiling of 1 in decoded linear RGB; HDR or rescaled scanner
captures require manual calibration. Dark holders and clipped regions contribute
no weight. User-defined ROIs/defect strokes and calibrated noise floors are not
part of this slice.

Base metering searches local narrow strips at 40 offsets in the outer 12%,
with eight independent segments on each of four sides. Candidates must have
unclipped opaque samples, channel variation below 4%, and transverse mean drift
below 1.2%. Matching segments must agree within 3.5% and be brighter than the
interior. Multiple sides provide stronger support than one side. The broad-band
90th percentile remains a fallback for an entirely flat film border; otherwise
the 99.5th interior percentile is an explicitly low-confidence estimate.
Auto Crop carries validated border estimates from the original source into the
cropped frame, so cropping cannot replace clear-film evidence with scene pixels.
Confidence is a heuristic, not a probability or a physical colour guarantee.

Per-threadgroup UInt32 histograms (4096 bins) merge into GPU histograms; compact
CDF selection runs entirely on GPU. Log transmission spans [-6,1.25] (bin width
.00177 log units), and density spans [-1,6] (bin width .001709 D). Bin centers
approximate quantiles without within-bin refinement. Under/overflow densities
enter edge bins and their fraction reduces endpoint confidence. The scene's 1st
and 99th density percentiles establish endpoints. Rank resolution is limited by
the valid sample count; this is not a promise of extreme-tail accuracy. When
neutral balancing is active, the green axis is the reference coordinate.

A second reduction fits D[c] = offset[c] + slope[c] * D[G], using samples in the
central 10–90% of each provisional channel range whose normalized channel spread
is at most .12. Float32 block moments reduce to a least-squares neutral axis on
GPU. Endpoint confidence uses valid fraction and density span independently of neutral-axis support. Balance confidence additionally requires at least 16 candidate samples, density leverage, up to 512 support samples, and a residual measured relative to scene density span. When base is automatic, its uncertainty also reduces endpoint and
balance confidence. Implausible fits (slopes outside [.25,4], offsets outside [-1,1])
or confidence <= .1 yield an identity axis. With a supported axis, development
uses (D-offset)/slope before endpoint normalization. This statistical assumption
can be wrong for strongly colored scenes; inspect the estimate or lock/override
it. Manual shift and slope controls use the same density-coordinate equation.
Automatic endpoints use the common green-axis limits; manual endpoints continue
to allow per-channel calibration.

The 96-byte summary is both consumed directly by the develop kernel and read
back for UI labels. Samples, partial histograms, CDF input, and fit moments remain
GPU buffers. Analysis scratch storage is about 17 MB at the maximum grid size,
independent of full image size. Four immutable summaries are cached by source
identity and effective base (automatic or exact manual RGB). Print, endpoint,
and balance edits reuse analysis; changing a locked base recomputes density
statistics. The full-size decoded texture is reused while URL, file modification
time, size and inode match. Replacing/editing the source or clearing its cache
creates a new identity. Preview and export always meter the whole native frame;
there is no per-tile or preview-resolution calibration.

Additional Swift Testing tests compare known base, robust bounds, and a casted
neutral wedge against an independent sorted-sample Float64 oracle; check missing
border/heavy-clipping confidence, invalid pixels, cache behavior, manual overrides
and lock persistence; render automatic/manual UI states offscreen; and record
24 MP metering wall/GPU/cached timings. The shared Rawr scheme includes only the
unhosted unit target, with no TEST_HOST or BUNDLE_LOADER and no UI tests.

## Roll consistency (baseline version 1)

Connect Folder Input to Negative Develop, optionally through Dust Removal and Auto Crop, and choose **Measure folder roll**. Use one film roll with a consistent capture setup. Measurement streams
native-resolution sources one at a time, retaining only each frame's compact
GPU metering summary. It requires at least three reliable frames and supports
up to 4096 files. Decode failure aborts measurement without replacing a saved
baseline. Measurement runs in the same request queue as preview and export.

A second Metal kernel performs all cross-frame statistics. Candidate frames
need base and endpoint confidence >= .5, valid sample fraction
>= .8, out-of-domain density fraction < .1, and density span >= .2. Blanks,
severe clipping and missing borders therefore cannot set the base/endpoint baseline. A shared neutral axis independently requires at least three accepted frames with balance confidence >= .5; otherwise balance remains automatic per frame. Trusted manual groups retain priority during measurement. Among candidates, median/MAD rejection runs on log10 RGB
base, green density span and green density midpoint. Thresholds are
max(4.4478 * MAD, floor), with floors .04 log10 base, .3 density span and .6
density midpoint. Thresholds are frozen before rejection. Accepted-frame
component medians form the supported shared groups; confidence
is median frame confidence multiplied by the accepted fraction of all frames.
Fewer than three accepted frames produces no saved baseline.

For accepted frames, the GPU saves the difference between its density midpoint
and the roll midpoint. Development subtracts this scalar **after neutral-axis
normalization and before endpoint normalization**. This aligns comparable
neutral distributions despite exposure differences; it assumes comparable
scene density distributions across the roll. It cannot distinguish a truly
darker scene from an exposure error. Review the result and use the individual
frame toggle for intentionally high-key/low-key scenes. Excluded frames still
receive the shared calibration but get no estimated density shift. Outlier
exclusion changes measurement, not the batch file list: all frames export.

The node shows the version, confidence, accepted count, RGB base, density
endpoints, neutral shift/slope, and selected frame's participation/alignment.
**Frame exposure trim (EV)** adds to the node's print exposure. **Use individual
frame settings** bypasses shared calibration and density alignment for that
frame, using the node's normal auto/manual groups. **Save frame override** snapshots the node’s manual numeric fields into a saved frame override;
it sets automatic groups off and density alignment to zero. Clear that override
to resume normal selection. A saved frame override takes precedence over node
and roll values, including exposure. Manual node groups take precedence over
shared roll groups; automatic groups select the roll's saved numbers. The
resulting complete calibration is validated before GPU rendering.

The baseline and frame edits are Codable node data saved inside `.flow`, with
algorithm/schema version 1 and a measurement revision UUID. File names, byte
sizes and fractional modification timestamps identify the measured sources.
Timestamps are stored as numbers so document ISO-8601 date formatting cannot
truncate them. A changed selected source or unsupported baseline fails rendering
with a remeasurement instruction. Batch export preflights the entire saved
manifest before writing, including added or removed files. Re-measure or remove
the baseline after moving the folder or changing files. Re-measurement replaces
both calibration and frame edits; it does not happen implicitly on export.
Old documents have no roll baseline and retain their existing behavior.

This is an independent RawrKit/Metal implementation based on the density model
above and standard robust statistics. No NegPy source was read, copied, linked,
or executed for this feature. The synthetic roll tests specify their own known
base, cast, exposure shifts and outliers, verify positive neutral agreement,
exercise saved overrides/opt-out, round-trip document data, and perform actual
folder measurement and batch TIFF export. The GPU-only 36 x 24 MP benchmark measures synthetic-source generation, frame
metering and roll reduction separately. A second end-to-end benchmark writes 36
24 MP profiled TIFF fixtures, times folder measurement including decode, saves
and reloads the flow, then times all 36 TIFF exports including decode, develop
and disk writes. Fixture preparation is reported separately. Both report the
VM's Metal device. The smooth synthetic gradients and warm filesystem do not
establish real camera-RAW/scanner throughput.
