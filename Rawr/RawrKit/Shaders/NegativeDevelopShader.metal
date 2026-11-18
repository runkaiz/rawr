#include <metal_stdlib>
using namespace metal;

struct NegativeDevelopParameters {
    float4 base;
    float4 low;
    float4 high;
    float4 print;
    float4 balance;
    float4 slope;
};

struct DevelopMeterResult { float4 base, low, high, offset, slope, quality; };

// Explicit float arithmetic throughout, including texture storage. No half mode.
kernel void negativeDevelop(texture2d<float, access::read> input [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]],
                            constant NegativeDevelopParameters &p [[buffer(0)]],
                            device const DevelopMeterResult &meter [[buffer(1)]],
                            constant uint4 &automatic [[buffer(2)]],
                            uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= output.get_width() || xy.y >= output.get_height()) return;
    float4 pixel = input.read(xy);
    float alpha = isfinite(pixel.a) ? clamp(pixel.a, 0.0f, 1.0f) : 0.0f;
    float3 positive = float3(0.0f);
    for (uint c = 0; c < 3; ++c) {
        // Input/output textures use premultiplied alpha; density uses straight RGB.
        float sample = alpha > 0.0f ? pixel[c] / alpha : 0.0f;
        // Invalid/negative samples are treated as zero; +Inf is saturated at base.
        sample = isnan(sample) || sample < 0.0f ? 0.0f : sample;
        float base = automatic.x ? meter.base[c] : p.base[c];
        float transmission = clamp(sample / base, 1e-6f, 1.0f);
        float density = -precise::log10(transmission);
        float offset = automatic.z ? meter.offset[c] : p.balance[c];
        float slope = automatic.z ? meter.slope[c] : p.slope[c];
        density = (density - offset) / slope - p.balance.w;
        uint endpointChannel = automatic.z ? 1 : c;
        float low = automatic.y ? meter.low[endpointChannel] : p.low[c];
        float high = automatic.y ? meter.high[endpointChannel] : p.high[c];
        float x = clamp((density - low) / (high - low), 0.0f, 1.0f);
        x = clamp(x * precise::exp2(p.print.x), 0.0f, 1.0f);
        x = clamp(0.5f + p.print.y * (x - 0.5f), 0.0f, 1.0f);
        // Endpoint-preserving cubic Hermite response. Its derivative is >= 0.5
        // for toe/shoulder in [0, .5], and it is identity when both are zero.
        float y = x + x * (1.0f - x) * (p.print.w * x - p.print.z * (1.0f - x));
        positive[c] = clamp(y, 0.0f, 1.0f) * alpha;
    }
    output.write(float4(positive, alpha), xy);
}
