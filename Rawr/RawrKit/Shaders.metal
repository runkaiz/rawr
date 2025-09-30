#include <metal_stdlib>
using namespace metal;

kernel void invertColors(texture2d<float, access::read> inputTexture [[texture(0)]],
                         texture2d<float, access::write> outputTexture [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 inputColor = inputTexture.read(gid);

    float4 invertedColor = float4(1.0 - inputColor.r,
                                   1.0 - inputColor.g,
                                   1.0 - inputColor.b,
                                   inputColor.a);

    outputTexture.write(invertedColor, gid);
}

kernel void filmNegativeInversion(texture2d<float, access::read> inputTexture [[texture(0)]],
                                  texture2d<float, access::write> outputTexture [[texture(1)]],
                                  constant float &orangeMaskR [[buffer(0)]],
                                  constant float &orangeMaskG [[buffer(1)]],
                                  constant float &orangeMaskB [[buffer(2)]],
                                  constant float &gamma [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 inputColor = inputTexture.read(gid);

    float3 orangeMask = float3(orangeMaskR, orangeMaskG, orangeMaskB);

    float3 corrected = inputColor.rgb / orangeMask;
    corrected = clamp(corrected, 0.0, 1.0);

    float3 inverted = 1.0 - corrected;

    float3 gammaAdjusted = pow(inverted, gamma);

    float4 outputColor = float4(gammaAdjusted, inputColor.a);
    outputTexture.write(outputColor, gid);
}

kernel void exposureAdjustment(texture2d<float, access::read> inputTexture [[texture(0)]],
                               texture2d<float, access::write> outputTexture [[texture(1)]],
                               constant float &exposure [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float4 inputColor = inputTexture.read(gid);

    float3 adjusted = inputColor.rgb * pow(2.0, exposure);
    adjusted = clamp(adjusted, 0.0, 1.0);

    float4 outputColor = float4(adjusted, inputColor.a);
    outputTexture.write(outputColor, gid);
}
