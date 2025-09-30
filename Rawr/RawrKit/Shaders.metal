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

// MARK: - Copy (Pass-through)

kernel void copyTexture(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 color = inputTexture.read(gid);
    outputTexture.write(color, gid);
}
