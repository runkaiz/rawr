#!/bin/bash
# Build on the build VM. The resulting bundle runs headlessly on macOS.
set -euo pipefail
OUT="${1:?usage: build-benchmark.sh /absolute/output/RawrBenchmark.bundle}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/air"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>xyz.runkaizhang.RawrBenchmark</string>
<key>CFBundleExecutable</key><string>rawr-benchmark</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
for shader in "$ROOT"/Rawr/RawrKit/Shaders/*.metal; do
    xcrun metal -c -fno-fast-math "$shader" -o "$OUT/air/$(basename "${shader%.metal}").air"
done
xcrun metallib "$OUT"/air/*.air -o "$OUT/Contents/Resources/default.metallib"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$ROOT/Rawr/RawrKit" -name '*.swift' -print0)
xcrun swiftc -O -parse-as-library -module-name RawrBenchmark "${SOURCES[@]}" \
    "$ROOT/Benchmarks/PipelineBenchmark.swift" -o "$OUT/Contents/MacOS/rawr-benchmark"
codesign --force --sign - "$OUT/Contents/MacOS/rawr-benchmark"
