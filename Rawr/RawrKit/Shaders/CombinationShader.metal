#include <metal_stdlib>
using namespace metal;

// MARK: - Image Combination

// Helper function to calculate luminance
half getLuminance(half3 color) {
    return dot(color, half3(0.2126, 0.7152, 0.0722)); // Rec. 709 luma coefficients
}

kernel void combineImages(
    texture2d<half, access::read> textureA [[texture(0)]],
    texture2d<half, access::read> textureB [[texture(1)]],
    texture2d<half, access::write> outputTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 colorA = textureA.read(gid);
    half4 colorB = textureB.read(gid);

    // Calculate luminance for both images
    half lumaA = getLuminance(colorA.rgb);
    half lumaB = getLuminance(colorB.rgb);

    // Determine which image is brighter at this pixel
    // We'll blend based on luminance to create an HDR-like result

    // Calculate blend weight based on luminance
    // For bright pixels (>0.5): favor the darker image
    // For dark pixels (<0.5): favor the brighter image
    half avgLuma = (lumaA + lumaB) * 0.5h;

    half weightA, weightB;
    if (avgLuma > 0.5h) {
        // Bright area: favor darker image
        weightA = (lumaA < lumaB) ? 0.7h : 0.3h;
        weightB = 1.0h - weightA;
    } else {
        // Dark area: favor brighter image
        weightA = (lumaA > lumaB) ? 0.7h : 0.3h;
        weightB = 1.0h - weightA;
    }

    // Blend the images
    half4 outputColor = half4(
        colorA.rgb * weightA + colorB.rgb * weightB,
        (colorA.a + colorB.a) * 0.5h // Average alpha
    );

    outputTexture.write(outputColor, gid);
}
