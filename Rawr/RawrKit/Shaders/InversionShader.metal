#include <metal_stdlib>
using namespace metal;

// MARK: - Inversion Shader (Film Negative)

kernel void invertImage(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 inputColor = inputTexture.read(gid);

    // Invert RGB channels, preserve alpha
    half4 outputColor = half4(
        1.0h - inputColor.r,
        1.0h - inputColor.g,
        1.0h - inputColor.b,
        inputColor.a
    );

    outputTexture.write(outputColor, gid);
}