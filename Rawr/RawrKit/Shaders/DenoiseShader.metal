#include <metal_stdlib>
using namespace metal;

// MARK: - Bilateral Filter Denoising

kernel void bilateralDenoise(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant float &strength [[buffer(0)]],
    constant float &colorSigma [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    // Bilateral filter: combines spatial and color similarity
    // Kernel size based on strength (1.0 = 3x3, 2.0 = 5x5, etc.)
    int kernelRadius = max(1, int(strength * 2.0));

    half4 centerColor = inputTexture.read(gid);
    half4 sumColor = half4(0.0);
    float sumWeight = 0.0;

    // Spatial sigma based on kernel radius
    float spatialSigma = float(kernelRadius);
    float spatialCoeff = -1.0 / (2.0 * spatialSigma * spatialSigma);
    float colorCoeff = -1.0 / (2.0 * colorSigma * colorSigma);

    // Sample neighborhood
    for (int dy = -kernelRadius; dy <= kernelRadius; dy++) {
        for (int dx = -kernelRadius; dx <= kernelRadius; dx++) {
            int2 offset = int2(dx, dy);
            uint2 samplePos = uint2(int2(gid) + offset);

            // Boundary check
            if (samplePos.x >= inputTexture.get_width() || samplePos.y >= inputTexture.get_height()) {
                continue;
            }

            half4 sampleColor = inputTexture.read(samplePos);

            // Spatial distance weight
            float spatialDist = float(dx * dx + dy * dy);
            float spatialWeight = exp(spatialDist * spatialCoeff);

            // Color distance weight (only RGB channels)
            half3 colorDiff = sampleColor.rgb - centerColor.rgb;
            float colorDist = dot(float3(colorDiff), float3(colorDiff));
            float colorWeight = exp(colorDist * colorCoeff);

            // Combined weight
            float weight = spatialWeight * colorWeight;

            sumColor += sampleColor * half(weight);
            sumWeight += weight;
        }
    }

    // Normalize and preserve alpha
    half4 outputColor;
    if (sumWeight > 0.0) {
        outputColor = half4((sumColor / half(sumWeight)).rgb, centerColor.a);
    } else {
        outputColor = centerColor;
    }

    outputTexture.write(outputColor, gid);
}
