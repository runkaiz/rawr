#include <metal_stdlib>
using namespace metal;

constant uint cropBins = 256;
constant uint cropAngles = 65; // -8 through +8 degrees, quarter-degree steps
// Explicit bilinear reads also work on devices without optional float32
// hardware filtering; full-precision transmittance need not be down-converted.
float4 cropSample(texture2d<float, access::read> image, float2 point) {
    float2 size(image.get_width(),image.get_height());
    float2 p=clamp(point-0.5f,float2(0),size-1.0f);
    uint2 a=uint2(floor(p)), b=min(a+1,uint2(size)-1);
    float2 t=fract(p);
    return mix(mix(image.read(a),image.read(uint2(b.x,a.y)),t.x),
        mix(image.read(uint2(a.x,b.y)),image.read(b),t.x),t.y);
}

float2 cropPoint(float2 uv, float angle, float2 size) {
    float2 p = (uv - 0.5f) * size;
    float c = cos(angle), s = sin(angle);
    return float2(c*p.x - s*p.y, s*p.x + c*p.y) + size*0.5f;
}

float cropLuma(float4 p) {
    return dot(max(p.rgb / max(p.a, 1e-6f), 0.0f), float3(0.2126f,0.7152f,0.0722f));
}

// Each thread integrates a line normal to an edge. Central line segments avoid
// sprockets, scanner rails, and corner leaks. Contrast is bounded per sample so
// isolated holes/hot spots cannot dominate an otherwise unsupported edge.
kernel void autoCropProjections(texture2d<float, access::read> image [[texture(0)]],
    device float *profiles [[buffer(0)]], uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= cropBins || tid.y >= 2 || tid.z >= cropAngles) return;
    float2 size(image.get_width(),image.get_height());
    float angle = (float(tid.z)-32.0f)*0.25f*M_PI_F/180.0f;
    float score = 0, support = 0;
    for (uint i = 0; i < 96; ++i) {
        float t = 0.28f + (float(i)+0.5f)/96.0f*0.44f;
        float q = (float(tid.x)+0.5f)/float(cropBins);
        float2 uv = tid.y == 0 ? float2(q,t) : float2(t,q);
        float2 delta = tid.y == 0 ? float2(1.0f/cropBins,0) : float2(0,1.0f/cropBins);
        float2 p = cropPoint(uv-delta,angle,size), r = cropPoint(uv+delta,angle,size);
        if (any(p < 0.5f) || any(p >= size-0.5f) || any(r < 0.5f) || any(r >= size-0.5f)) continue;
        float a = cropLuma(cropSample(image,p)), b = cropLuma(cropSample(image,r));
        float contrast = abs(a-b)/max(0.04f,max(a,b));
        if (!isfinite(contrast)) continue;
        score += min(contrast,1.0f);
        support += contrast > 0.10f ? 1.0f : 0.0f;
    }
    profiles[(tid.z*2+tid.y)*cropBins+tid.x] = score/96.0f * support/96.0f;
}

// Four edges + score/confidence in 32 bytes per angle; 2080 bytes reach CPU.
struct CropCandidate { float4 bounds; float4 quality; };
kernel void autoCropSelect(device const float *profiles [[buffer(0)]],
    device CropCandidate *candidates [[buffer(1)]], uint angle [[thread_position_in_grid]]) {
    if (angle >= cropAngles) return;
    float4 bounds(0), peaks(0), ratios(0);
    for (uint axis=0; axis<2; ++axis) {
        device const float *p = profiles+(angle*2+axis)*cropBins;
        float mean = 0;
        for (uint j=16;j<240;++j) mean += p[j]/224.0f;
        for (uint side=0;side<2;++side) {
            uint start = side == 0 ? 16 : 139, end = side == 0 ? 117 : 240;
            float maximum = 0;
            for (uint j=start;j<end;++j) maximum=max(maximum,p[j]);
            // Among substantial local peaks, choose the innermost edge of the
            // central frame. Outer rails may be stronger than the exposure.
            uint index = start; float best=0;
            for (uint j=start+1;j<end-1;++j) {
                if(p[j] < maximum*0.45f || p[j] < p[j-1] || p[j] < p[j+1]) continue;
                float proximity = side == 0 ? float(j)/256.0f : 1.0f-float(j)/256.0f;
                float score=proximity+0.03f*p[j];
                if(score>best) { best=score; index=j; }
            }
            uint c=axis*2+side;
            bounds[c]=(float(index)+0.5f)/cropBins;
            peaks[c]=p[index]; ratios[c]=p[index]/max(mean,0.001f);
        }
    }
    float minimum = min(min(peaks.x,peaks.y),min(peaks.z,peaks.w));
    float ratio = min(min(ratios.x,ratios.y),min(ratios.z,ratios.w));
    float confidence = clamp(minimum/0.20f,0.0f,1.0f)*clamp((ratio-1.5f)/4.0f,0.0f,1.0f);
    float score = sqrt(max(0.0f,peaks.x*peaks.y))*sqrt(max(0.0f,peaks.z*peaks.w));
    candidates[angle] = {bounds,float4(score,confidence,minimum,ratio)};
}

struct CropTransform { float4 rect; float4 rotation; }; // cx,cy,w,h; radians
kernel void autoCropResample(texture2d<float, access::read> image [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant CropTransform &cfg [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x>=output.get_width() || xy.y>=output.get_height()) return;
    float2 uv=(float2(xy)+0.5f)/float2(output.get_width(),output.get_height());
    float2 local=(uv-0.5f)*cfg.rect.zw;
    float2 size(image.get_width(),image.get_height());
    float2 p=cropPoint(local+0.5f,cfg.rotation.x,size)+(cfg.rect.xy-0.5f)*size;
    output.write(cropSample(image,p),xy);
}

// Validate narrow strips just outside the detected exposure, before cropping.
// A base needs two matching, bright, spatially uniform sides. Dark holders,
// clipped light tables, sprocket holes, leaks and scene texture are rejected.
kernel void autoCropBorder(texture2d<float, access::read> image [[texture(0)]],
    device float4 &result [[buffer(0)]], constant CropTransform &cfg [[buffer(1)]],
    uint tid [[thread_position_in_grid]]) {
    if (tid) return;
    float2 size(image.get_width(),image.get_height());
    float3 means[4], variances[4]; bool valid[4];
    for (uint side=0;side<4;++side) {
        float3 sum(0), square(0); uint count=0;
        for (uint i=0;i<128;++i) {
            float t=(float(i)+0.5f)/128.0f*0.6f-0.3f;
            float2 uv = side<2 ? float2((side==0 ? -1.0f:1.0f)*(cfg.rect.z*0.5f+0.012f),t*cfg.rect.w) :
                float2(t*cfg.rect.z,(side==2 ? -1.0f:1.0f)*(cfg.rect.w*0.5f+0.012f));
            float2 p=cropPoint(uv+0.5f,cfg.rotation.x,size)+(cfg.rect.xy-0.5f)*size;
            if (any(p<0.5f) || any(p>=size-0.5f)) continue;
            float4 sample=cropSample(image,p);
            float3 v=sample.rgb/max(sample.a,1e-6f);
            if (all(isfinite(v)) && all(v>0.002f) && all(v<0.995f) && sample.a>0.99f) {
                sum+=v; square+=v*v; ++count;
            }
        }
        means[side]=sum/max(1u,count);
        variances[side]=max(float3(0),square/max(1u,count)-means[side]*means[side]);
        valid[side]=count>=120 && all(sqrt(variances[side])/max(means[side],0.001f)<0.04f);
    }
    float3 interior(0);
    for(uint i=0;i<64;++i) {
        float2 uv=(float2(i%8,i/8)+0.5f)/8.0f-0.5f;
        float2 p=cropPoint(uv*cfg.rect.zw*0.8f+0.5f,cfg.rotation.x,size)+(cfg.rect.xy-0.5f)*size;
        interior+=cropSample(image,p).rgb/64.0f;
    }
    result=float4(0);
    for(uint a=0;a<4;++a) for(uint b=a+1;b<4;++b) {
        float3 base=(means[a]+means[b])*0.5f;
        if(valid[a] && valid[b] && all(abs(means[a]-means[b])/max(base,0.001f)<0.05f) &&
            all(base>interior*1.08f) && dot(base,float3(1))>dot(result.rgb,float3(1))) result=float4(base,1);
    }
}
