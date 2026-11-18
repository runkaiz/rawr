# Dust Removal

Connect **Image Input → Dust Removal → Negative Develop → Preview**, or use Folder Input.
For a positive scan, connect Dust Removal directly to Preview.
Cleanup runs on the full oriented source before negative metering and density conversion.

**Sensitivity** controls the contrast threshold; **Defect radius** sets the full-resolution sampling radius from 1 to 8 pixels.
Start conservatively, inspect **Show defect mask**, and compare fine detail before exporting.
The mask switch changes the preview only; export uses the repaired image.
The **Mask** output can also connect directly to Preview.
Automatic optical detection can mistake real compact detail for dirt.

Without IR, Metal compares opposing samples in four directions and finds a consensus among pairs with similar colors.
Pairs crossing a strong edge receive less influence; local variation raises the detection threshold.
Both dark specks/hairs and bright short scratches can be flagged.
Repair uses clean donors at three growing supports, color agreement weights, a bounded donor high-frequency residual, and a feathered mask blend.
Pixels outside the mask are copied exactly.
Large defects without clean donors are retained; this is a bounded local reconstruction, not a full-frame scratch or semantic inpainting system.

When an infrared channel is available, it is selected automatically.
A sparse GPU regression estimates the visible-image ghost in IR.
After subtracting the fitted ghost, separable dilation estimates the clean IR envelope and a short average smooths the reference.
The corrected IR/reference ratio produces a continuous defect mask.
Reconstruction uses the same edge-weighted clean donor path.
**IR ghost correction** scales the fitted subtraction; disable **Use infrared when present** for silver B&W, image-contaminated IR, or an unsuitable scanner.
IR registration and film suitability are user responsibilities.

Embedded IR import supports baseline TIFF with chunky RGB plus one unspecified extra sample (`ExtraSamples=0`), unsigned 8/16-bit samples, uncompressed strips, and either byte order.
Orientation applies to RGB and IR together; RGB honors the decoded profile while IR remains a scalar scanner measurement.
Ordinary alpha-tagged RGBA TIFF is never interpreted as infrared.
Compressed or planar RGB+IR layouts require an uncompressed export or a separate frame.
BigTIFF and vendor-specific channel conventions require a separate frame.
Use **IR frame…** to select a registered monochrome frame with matching oriented dimensions; its red sample is used without an ICC transfer conversion.
Its URL and security bookmark are saved in the document.
When no IR exists, processing falls back to optical detection.

For missed defects, add **Manual heal points** using X/Y percentages from the top-left of the oriented image and a radius percentage of its shorter edge.
Points use a solid core with a feathered rim and persist in `.flow` independently of preview size.
Each point can be removed, or all cleared; a node supports up to 128 points.

Detection, regression, morphology, reconstruction, and compositing are Metal compute passes in one command buffer with private intermediate textures.
There are no full-image CPU readbacks between these stages.
File decode/upload and terminal preview/export are the image boundaries.
Processing is full-frame rather than tiled, so memory and latency grow with scan size.

The implementation and synthetic fixtures were independently written from the check-up report's prose and general neighborhood-filtering concepts.
No NegPy or digital-fauxice source was opened or copied.
Swift Testing covers planted specks/hairs/scratches, bounded repair error, unchanged edges/grain, IR ghost/ratio detection, fallback, TIFF channel interpretation, manual-point persistence, preview rendering, and 24 MP GPU timings.
Real scans from the owner, with and without IR, are still needed to tune thresholds and assess photographic quality.
