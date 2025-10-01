#include <metal_stdlib>
using namespace metal;

// MARK: - Helper Functions

/// Compute Gaussian weight based on distance
inline float gaussianWeight(float distance, float sigma) {
    return exp(-distance / (2.0 * sigma * sigma));
}

/// Apply bilateral filter for denoising (chroma or full)
half4 bilateralFilter(
    texture2d<half, access::read> texture,
    uint2 gid,
    int kernelRadius,
    float spatialSigma,
    float colorSigma,
    bool chromaOnly
) {
    half4 centerColor = texture.read(gid);
    half4 sumColor = half4(0.0);
    float sumWeight = 0.0;

    float spatialCoeff = -1.0 / (2.0 * spatialSigma * spatialSigma);
    float colorCoeff = -1.0 / (2.0 * colorSigma * colorSigma);

    for (int dy = -kernelRadius; dy <= kernelRadius; dy++) {
        for (int dx = -kernelRadius; dx <= kernelRadius; dx++) {
            int2 offset = int2(dx, dy);
            uint2 samplePos = uint2(int2(gid) + offset);

            if (samplePos.x >= texture.get_width() || samplePos.y >= texture.get_height()) {
                continue;
            }

            half4 sampleColor = texture.read(samplePos);

            // Spatial distance weight
            float spatialDist = float(dx * dx + dy * dy);
            float spatialWeight = exp(spatialDist * spatialCoeff);

            // Color distance weight
            half3 colorDiff = sampleColor.rgb - centerColor.rgb;
            float colorDist = dot(float3(colorDiff), float3(colorDiff));
            float colorWeight = exp(colorDist * colorCoeff);

            float weight = spatialWeight * colorWeight;

            sumColor += sampleColor * half(weight);
            sumWeight += weight;
        }
    }

    if (sumWeight > 0.0) {
        if (chromaOnly) {
            // Only apply bilateral to chroma channels (preserve luma)
            half3 denoisedRGB = (sumColor / half(sumWeight)).rgb;
            // Simple RGB to YCbCr approximation
            half Y = 0.299 * centerColor.r + 0.587 * centerColor.g + 0.114 * centerColor.b;
            half Cb = -0.169 * denoisedRGB.r - 0.331 * denoisedRGB.g + 0.5 * denoisedRGB.b;
            half Cr = 0.5 * denoisedRGB.r - 0.419 * denoisedRGB.g - 0.081 * denoisedRGB.b;
            // Convert back to RGB
            half r = Y + 1.402 * Cr;
            half g = Y - 0.344 * Cb - 0.714 * Cr;
            half b = Y + 1.772 * Cb;
            return half4(r, g, b, centerColor.a);
        } else {
            return half4((sumColor / half(sumWeight)).rgb, centerColor.a);
        }
    }
    return centerColor;
}

/// Richardson-Lucy deconvolution for sharpening
half4 richardsonLucyDeconvolution(
    texture2d<half, access::read> texture,
    uint2 gid,
    float radius,
    int iterations
) {
    half4 centerColor = texture.read(gid);
    int kernelRadius = max(1, int(radius));

    // Start with input image as initial estimate
    half4 estimate = centerColor;

    // Richardson-Lucy iterations
    for (int iter = 0; iter < iterations; iter++) {
        half4 reblurred = half4(0.0);
        float totalWeight = 0.0;

        // Gaussian kernel for PSF (Point Spread Function)
        float sigma = radius;

        for (int dy = -kernelRadius; dy <= kernelRadius; dy++) {
            for (int dx = -kernelRadius; dx <= kernelRadius; dx++) {
                uint2 samplePos = uint2(int2(gid) + int2(dx, dy));

                if (samplePos.x >= texture.get_width() || samplePos.y >= texture.get_height()) {
                    continue;
                }

                float dist = float(dx * dx + dy * dy);
                float weight = gaussianWeight(dist, sigma);

                half4 sampleColor = texture.read(samplePos);
                reblurred += sampleColor * half(weight);
                totalWeight += weight;
            }
        }

        if (totalWeight > 0.0) {
            reblurred /= half(totalWeight);

            // RL update: estimate *= (input / reblurred)
            half4 ratio = centerColor / (reblurred + half4(0.001)); // Add epsilon to avoid division by zero
            estimate *= ratio;
        }
    }

    return half4(estimate.rgb, centerColor.a);
}

/// Unsharp mask sharpening (creative/output stage)
half4 unsharpMask(
    texture2d<half, access::read> texture,
    uint2 gid,
    float amount,
    float radius
) {
    half4 centerColor = texture.read(gid);
    int kernelRadius = max(1, int(radius));

    // Gaussian blur
    half4 blurred = half4(0.0);
    float totalWeight = 0.0;
    float sigma = radius;

    for (int dy = -kernelRadius; dy <= kernelRadius; dy++) {
        for (int dx = -kernelRadius; dx <= kernelRadius; dx++) {
            uint2 samplePos = uint2(int2(gid) + int2(dx, dy));

            if (samplePos.x >= texture.get_width() || samplePos.y >= texture.get_height()) {
                continue;
            }

            float dist = float(dx * dx + dy * dy);
            float weight = gaussianWeight(dist, sigma);

            half4 sampleColor = texture.read(samplePos);
            blurred += sampleColor * half(weight);
            totalWeight += weight;
        }
    }

    if (totalWeight > 0.0) {
        blurred /= half(totalWeight);

        // Unsharp mask: sharpened = original + amount * (original - blurred)
        half4 detail = centerColor - blurred;
        half4 sharpened = centerColor + detail * half(amount);

        return half4(sharpened.rgb, centerColor.a);
    }

    return centerColor;
}

// MARK: - Main Sharpening Kernel

kernel void advancedSharpening(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    constant int &algorithm [[buffer(0)]],
    constant float &strength [[buffer(1)]],
    constant float &radius [[buffer(2)]],
    constant int &iterations [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 color = inputTexture.read(gid);

    if (algorithm == 0) {
        // DEFAULT ALGORITHM: Bilateral denoise → Deconvolution capture sharpen → Creative → Output sharpen
        // Safest for most files, especially medium/high ISO

        // Stage 1: Bilateral denoise to remove sensor noise
        int denoiseRadius = 2;
        float spatialSigma = 2.0;
        float colorSigma = 0.15;
        color = bilateralFilter(inputTexture, gid, denoiseRadius, spatialSigma, colorSigma, false);

        // Stage 2: Deconvolution capture sharpening
        int rlIterations = max(2, min(5, iterations));
        half4 tempTexture = richardsonLucyDeconvolution(inputTexture, gid, radius, rlIterations);
        color = mix(color, tempTexture, half(0.6 * strength)); // Blend deconvolved result

        // Stage 3: Creative sharpening (moderate unsharp mask)
        half4 creative = unsharpMask(inputTexture, gid, 0.3 * strength, radius * 0.8);
        color = mix(color, creative, half(0.5));

        // Stage 4: Output sharpening (subtle final pass)
        half4 output = unsharpMask(inputTexture, gid, 0.2 * strength, radius * 0.5);
        color = mix(color, output, half(0.4));

    } else {
        // DETAIL-MAX ALGORITHM: Deconvolution (light) → Very light bilateral on chroma → Creative → Output
        // For low ISO, rich texture, tripod/landscape photography

        // Stage 1: Light deconvolution to preserve micro-detail
        int rlIterations = max(2, min(4, iterations));
        color = richardsonLucyDeconvolution(inputTexture, gid, radius * 0.7, rlIterations);

        // Stage 2: Very light bilateral on chroma only (mop up residual noise without touching edges)
        int chromaDenoiseRadius = 1;
        float chromaSpatialSigma = 1.0;
        float chromaColorSigma = 0.1;
        half4 chromaDenoise = bilateralFilter(inputTexture, gid, chromaDenoiseRadius, chromaSpatialSigma, chromaColorSigma, true);
        color = mix(color, chromaDenoise, half(0.3));

        // Stage 3: Creative sharpening (stronger to emphasize detail)
        half4 creative = unsharpMask(inputTexture, gid, 0.5 * strength, radius * 0.9);
        color = mix(color, creative, half(0.7));

        // Stage 4: Output sharpening (final detail enhancement)
        half4 output = unsharpMask(inputTexture, gid, 0.3 * strength, radius * 0.6);
        color = mix(color, output, half(0.5));
    }

    // Clamp to valid range and write output
    color = clamp(color, half4(0.0), half4(1.0));
    outputTexture.write(color, gid);
}
