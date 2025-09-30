#include <metal_stdlib>
using namespace metal;

// MARK: - Gamma Correction

kernel void applyGamma(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant float &gamma [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 inputColor = inputTexture.read(gid);

    // Apply gamma correction
    half4 outputColor = half4(
        pow(inputColor.r, half(1.0 / gamma)),
        pow(inputColor.g, half(1.0 / gamma)),
        pow(inputColor.b, half(1.0 / gamma)),
        inputColor.a
    );

    outputTexture.write(outputColor, gid);
}