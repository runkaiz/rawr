#include <metal_stdlib>
using namespace metal;

// MARK: - Exposure Adjustment

kernel void adjustExposure(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant float &exposureStops [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 inputColor = inputTexture.read(gid);

    // Exposure adjustment: multiply by 2^stops
    float multiplier = pow(2.0, exposureStops);
    half4 outputColor = half4(
        inputColor.rgb * half(multiplier),
        inputColor.a
    );

    outputTexture.write(outputColor, gid);
}