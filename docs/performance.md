# GPU execution and benchmarks

Rawr's graph keeps effect results in Metal textures. Legacy effects no longer
read each texture back through a Swift array and CGContext. Preview creates a
display-sized image at the terminal boundary; GPU-only export passes the texture
directly to Core Image's file writer. The Before image is reused until its source
or preview size changes. Negative Develop still evaluates the full-resolution
source before preview resampling, so local dust supports and global metering do
not change with the preview size.

## Resource ownership and memory

`MetalResources` caches compute pipeline states by function name. Batch workers
share this cache and a pool of completed private textures and scratch buffers.
The pool's idle storage is capped at the smaller of 512 MiB and one quarter of
the device's recommended working set. Live resources are additional to that cap.
Returning a resource can evict older idle storage so small scratch allocations
cannot prevent a large output from being reused on the next slider edit.

Each `ImageData` retains its output's lease. A caller extracting a texture must
retain that `ImageData` until every GPU/CI use has completed. Encoders retain
Metal resources, but that alone does not stop the pool from reusing a resource;
the lease owns that protection. Scratch leases live through command completion.
Export explicitly retains its input through the asynchronous file write.

The executor releases an ancestor after its final reachable consumer completes,
and serializes requests even when callers invoke its actor concurrently. Source
uploads are reused by URL, modification time, size, inode and resolution mode.
Dust results are reused by source content identity, controls, repair spots and
the external IR file identity. Canvas placement has no effect on that cache.
The dust cache retains one result, capped at 768 MiB or half the recommended
working set, whichever is smaller. It is disabled during full-resolution export.

Roll export streams at most two frames concurrently. Each worker has its own
decoder, CI contexts, command queue, source cache and executor. The memory policy
budgets 96 bytes per pixel plus 256 MiB per frame, increases the estimate for
longer graphs, and limits the budget to half the recommended GPU working set or
one third of physical RAM. RAW files and unknown dimensions use one worker.
Only compact summaries accumulate during roll calibration. Logs retain 500 rows.

Core Image file writing and disabled intermediate caching avoid an explicit
full-frame CPU image at export. This delegates boundary rendering to Core Image;
the compute graph still requires full-size source/result textures. It is not an
out-of-core decoder or a guarantee that a 128 MP graph fits a 4 GiB machine.

## Accuracy

The shader formulas and precision are unchanged. Transmittance, IR correction,
density, metering and development remain float32. The existing dust mask uses
half storage in [0,1]; binary16 rounding there is at most 1/4096 absolute, and
this change introduces no new half-precision conversion. Legacy effects retain
their existing half arithmetic. Negative Develop's shader/reference tolerance
remains 1e-5 absolute, and preview versus resampled export remains 4/65535.
Negative TIFF/PNG use unsigned 16-bit linear RGB at the final boundary; legacy
half-float TIFF retains values above display white. JPEG remains lossy.

All implementations are native Swift/Metal/Core Image. No NegPy source or runtime
is incorporated.

## Reproduction

Build the headless harness on a Mac build worker with the Xcode Metal component:

```sh
bash scripts/build-benchmark.sh /absolute/task/path/RawrBenchmark.bundle
/absolute/task/path/RawrBenchmark.bundle/Contents/MacOS/rawr-benchmark \
    --width 6000 --height 4000 --frames 36 --iterations 5 \
    --output /absolute/task/path/results.json
```

The binary is invoked directly and has no application/window entry point. A
VM-built bundle can be copied to the matching macOS host for GPU measurement;
no host build is needed. The Firstmate runner additionally holds the shared VM
lock, uses ad hoc signing with no team, and guards host compute with HID idle
time >=10 minutes throughout the run. No UI test target is needed.

The fixtures are generated linear gradients with a separate registered IR
frame; 36 distinct paths link to the same visible fixture bytes. They exercise
decode, dust/IR, metering, development, preview, TIFF export, batch scheduling and
roll calibration, but do not model varied photographic content or disk-cold
private scans. Fixture generation is excluded from reported scenario time.

JSON contains total wall time for cold preview, each exposure-slider edit,
single TIFF export, 36-frame TIFF export and roll calibration. Events report
stage wall time, available completed-command GPU timestamps, and Metal allocated
bytes. Cache hits are named explicitly. Core Image's implicit preview/file-write
GPU work has no command timestamp and is included in boundary wall time; an
absent GPU value means unavailable, not zero. Metering wall time is nested in
development wall time, so stage wall times must not be summed. Scenario RSS is
the process lifetime high-water mark from `getrusage`, not incremental memory.
Metal allocation samples include live and idle pooled storage, but can miss a
short-lived intermediate peak. Repeat runs for statistically robust comparisons.
