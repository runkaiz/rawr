# Auto Crop

Connect `Image Input / Folder Input → Auto Crop → Negative Develop → Preview`.
Dust Removal may go before Auto Crop; registered embedded IR is transformed
along with RGB. An external IR file should be attached before the crop so its
source dimensions still match. Crop runs identically for preview and export,
using linear float textures. Oversized RAW working previews and the documented
full-resolution ceiling follow the [source contract](negative-develop.md).

Process the graph to see the proposed frame, clockwise rotation and confidence.
A confidence below 55% keeps a single image intact. Review the source-space
outline and processed preview. Editing center X/Y, width, height or rotation
locks a manual rectangle; center/size are percentages of the oriented source,
Y from the top. `Lock crop` freezes the current proposal. `Detect again`
returns to automatic operation. Rectangles extending outside the scan fail
with a log message instead of filling the crop with clamped edge pixels.

`Consistent size across roll` locks the current pixel dimensions. Each folder
frame still gets its own detected center and rotation. Center/rotation edits
save corrections keyed by that frame's source path; width/height edits change
the shared size. The `.flow` document saves manual geometry, reference size,
per-frame corrections, and the border-metering preference. Moving the sources
to different paths requires reapplying frame corrections. An uncertain or
out-of-bounds roll frame fails rather than silently producing a different size;
review those frames before exporting the roll.

Automatic detection assumes one approximately centered rectangular exposure.
Metal integrates bounded contrast along candidate edge normals at 65 angles
from −8° to +8°. Boundary searches include near-canvas scanner edges and stay
in the outer 35% of each axis. Automatic proposals must cover at least 12% of
the canvas; smaller scene rectangles retain the source for manual review.
Manual rectangles keep their existing size range. The central integration segments suppress sprockets and
corner leaks; paired inner edges suppress outer holder rails. Metal reduces
these projections to 65 candidates (2080 bytes), and CPU code ranks only these
summaries. A small inset excludes the transition itself. Straightening uses a
single GPU affine resampling pass, preserving float precision and registered
IR. Four detection summaries are cached by immutable image identity.

When at least two narrow strips outside the detected exposure agree, remain
unclipped and uniform, and are brighter than the exposure interior, their RGB
estimate is carried downstream as film-base metadata. Validated source-edge
strips provide additional evidence before cropping. Negative Develop uses the
retained estimate only with automatic base metering enabled. Disable `Meter base from detected
border` to use Negative Develop's existing border/interior fallback instead.
Manual base values retain priority. This is a conservative optical estimate,
not a scanner calibration or a film-stock profile.

The current transform corrects in-plane skew/rotation. It does not correct
camera perspective, lens distortion, curved film, multiple exposures per scan,
or strongly occluded/scene-filled frame boundaries. Rotation outside the search
range needs manual adjustment (up to ±12°) or a source orientation correction.
Confidence is heuristic, not a calibrated probability. Synthetic tests cover
known frames, holder rails, sprockets, corner leaks, camera light tables,
straightening, no-edge rejection, roll geometry, save/load, and exported pixels.
Tuning on the captain's real Plustek scans follows this initial clean-room slice.
No NegPy code, constants, fixtures or runtime dependencies were used.
