#include <metal_stdlib>
using namespace metal;

// Six float4s; mirrored by NegativeMeteringResult. Only this 96-byte summary
// crosses to CPU. Histograms, samples, and regression moments stay private.
struct MeterResult { float4 base, low, high, offset, slope, quality; };
struct MeterConfig { uint4 grid; float4 base; }; // width, height, sample count, auto base
constant uint bins = 4096;
constant float logRange = 7.25f; // log10 transmission [-6, 1.25]

struct BaseCandidate { float4 base, location; };
// Search narrow local strips, rather than demanding that an entire outer band
// be clear film. 80 offsets x 8 nonoverlapping segments x 4 canvas edges.
kernel void negativeMeterBaseCandidates(texture2d<float,access::read> image [[texture(0)]],
    device BaseCandidate *output [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    if(i>=2560) return;
    uint side=i/640, offset=(i%640)/8, segment=i%8;
    float2 size(image.get_width(),image.get_height());
    float3 sum(0), square(0), normal[3]={float3(0),float3(0),float3(0)};
    float3 normalSquare[3]={float3(0),float3(0),float3(0)}, blocks[16];
    for(uint b=0;b<16;++b) blocks[b]=float3(0);
    uint count=0;
    float center=(float(offset)+0.5f)/80.0f*0.12f;
    for(uint n=0;n<3;++n) for(uint j=0;j<64;++j) {
        float step=max(0.0012f,1.0f/(side<2 ? size.x:size.y));
        float across=center+(float(n)-1.0f)*step;
        float along=0.04f+(float(segment)+(float(j)+0.5f)/64.0f)/8.0f*0.92f;
        float2 uv=side<2 ? float2(side==0 ? across:1-across,along) :
            float2(along,side==2 ? across:1-across);
        if(any(uv<=0) || any(uv>=1)) continue;
        float4 p=image.read(min(uint2(uv*size),uint2(size)-1));
        float3 v=p.rgb/max(p.a,1e-6f);
        if(!all(isfinite(p)) || p.a<0.99f || any(v<=1e-5f) || any(v>=0.995f)) continue;
        sum+=v; square+=v*v; normal[n]+=v/64.0f;
        normalSquare[n]+=v*v/64.0f; blocks[j/4]+=v/12.0f; ++count;
    }
    float3 mean=sum/max(1u,count);
    float3 rawVariance=max(float3(0),square/max(1u,count)-mean*mean), blockVariance(0);
    for(uint b=0;b<16;++b) blockVariance+=(blocks[b]-mean)*(blocks[b]-mean)/16.0f;
    // Grain is sample noise, not spatial shading. Estimate the variance of
    // block means after subtracting their expected within-block noise.
    // Sixteen block variances have sampling uncertainty. A two-sigma noise
    // allowance prevents ordinary grain fluctuations from becoming shading.
    float3 noiseBound=rawVariance/12.0f*(1.0f+2.0f*sqrt(2.0f/15.0f));
    float3 cv=sqrt(max(float3(0),blockVariance-noiseBound))/max(mean,1e-6f);
    float3 meanError=sqrt(rawVariance/192.0f)/max(mean,1e-6f);
    float flat=max(max(cv.x,cv.y),cv.z);
    float3 trend=abs(normal[0]-normal[2])/max(mean,1e-6f);
    float3 noise=max(float3(0),normalSquare[0]-normal[0]*normal[0])+
        max(float3(0),normalSquare[2]-normal[2]*normal[2]);
    float3 trendTolerance=0.004f+2.5f*sqrt(noise/64.0f)/max(mean,1e-6f);
    bool valid=count==192 && flat<0.04f && all(trend<trendTolerance);
    // A smooth scene gradient can be locally flat. Require a supported edge
    // nearby; average whole line segments so individual grain/dust is not an edge.
    float edge=0, previous=0; bool havePrevious=false;
    if(valid) for(int k=-16;k<=16;++k) {
        float across=center+float(k)*0.003f;
        if(across<=0 || across>=1) { havePrevious=false; continue; }
        float line=0; uint support=0;
        for(uint j=0;j<64;++j) {
            float along=0.04f+(float(segment)+(float(j)+0.5f)/64.0f)/8.0f*0.92f;
            float2 uv=side<2 ? float2(side==0 ? across:1-across,along) :
                float2(along,side==2 ? across:1-across);
            float4 p=image.read(min(uint2(uv*size),uint2(size)-1));
            if(!all(isfinite(p)) || p.a<0.99f) continue;
            line+=dot(clamp(p.rgb/max(p.a,1e-6f)/max(mean,1e-6f),0.0f,2.0f),float3(1.0f/3.0f));
            ++support;
        }
        if(support<60) { havePrevious=false; continue; }
        line/=float(support);
        if(havePrevious) edge=max(edge,abs(line-previous));
        previous=line; havePrevious=true;
    }
    valid=valid && edge>0.12f;
    float uncertainty=max(max(meanError.x,meanError.y),meanError.z);
    float confidence=clamp(1-flat/0.08f,0.0f,1.0f)*clamp(1-uncertainty/0.05f,0.0f,1.0f);
    output[i]={float4(mean,valid ? confidence:0),float4(side,segment,offset,edge)};
}

kernel void negativeMeterBaseSelect(texture2d<float,access::read> image [[texture(0)]],
    device const BaseCandidate *candidates [[buffer(0)]], device MeterResult &r [[buffer(1)]],
    uint i [[thread_position_in_grid]]) {
    if(i) return;
    float3 interior(0); uint valid=0;
    for(uint j=0;j<256;++j) {
        float2 uv=0.15f+(float2(j%16,j/16)+0.5f)/16.0f*0.7f;
        float4 p=image.read(uint2(uv*float2(image.get_width(),image.get_height())));
        if(all(isfinite(p)) && p.a>0.99f) { interior+=p.rgb/p.a; ++valid; }
    }
    interior/=max(1u,valid);
    float best=-1e6f;
    for(uint a=0;a<2560;++a) {
        BaseCandidate p=candidates[a];
        if(p.base.w==0 || !all(p.base.rgb>interior*1.08f)) continue;
        uint sides=0,segments=0,votes=0; float3 sum(0); float confidence=0; uint count=0;
        for(uint b=0;b<2560;++b) {
            BaseCandidate q=candidates[b];
            if(q.base.w==0 || any(abs(q.base.rgb-p.base.rgb)/max(p.base.rgb,1e-6f)>0.035f)) continue;
            // One vote per segment prevents a wide strip at adjacent offsets
            // from fabricating independent support.
            uint bit=1u<<(uint(q.location.x)*8+uint(q.location.y));
            if(votes&bit) continue;
            votes|=bit;
            if(q.location.x==p.location.x) segments|=1u<<uint(q.location.y);
            sides|=1u<<uint(q.location.x);
            sum+=q.base.rgb; confidence+=q.base.w; ++count;
        }
        if(popcount(segments)<2 || count<2) continue;
        float score=dot(log(max(p.base.rgb,1e-6f)),float3(1));
        if(score>best) {
            best=score;
            float support=popcount(sides)>=2 ? 1.0f:0.75f;
            r.base=float4(sum/float(count),confidence/float(count)*support);
        }
    }
}

kernel void negativeMeterSample(texture2d<float, access::read> image [[texture(0)]],
    device float4 *samples [[buffer(0)]], constant MeterConfig &cfg [[buffer(1)]],
    uint i [[thread_position_in_grid]]) {
    if (i >= cfg.grid.z) return;
    uint2 cell(i % cfg.grid.x, i / cfg.grid.x);
    uint2 xy = min(uint2((float2(cell) + 0.5f) * float2(image.get_width(), image.get_height()) /
        float2(cfg.grid.xy)), uint2(image.get_width()-1, image.get_height()-1));
    float4 p = image.read(xy);
    float3 v = p.rgb / max(p.a, 1e-6f);
    bool valid = all(isfinite(p)) && p.a >= 0.99f && all(v > 1e-6f) && all(v < 0.99999f);
    bool border = any(float2(cell) < float2(cfg.grid.xy) * 0.05f) ||
        any(float2(cell) >= float2(cfg.grid.xy) * 0.95f);
    samples[i] = float4(valid ? v : float3(0), valid ? (border ? 2.0f : 1.0f) : 0.0f);
}

// One channel and one region per group. Local atomics avoid global contention.
// phase 0 = border log transmission; 1 = interior log transmission; 2 = density.
kernel void negativeMeterHistogram(device const float4 *samples [[buffer(0)]],
    device uint *partial [[buffer(1)]], device const MeterResult &r [[buffer(2)]],
    constant MeterConfig &cfg [[buffer(3)]], constant uint &phase [[buffer(4)]],
    uint lane [[thread_index_in_threadgroup]], uint3 group [[threadgroup_position_in_grid]]) {
    threadgroup atomic_uint histogram[4096];
    for (uint b = lane; b < bins; b += 256) atomic_store_explicit(&histogram[b], 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint j = lane; j < 1024; j += 256) {
        uint i = group.x * 1024 + j;
        if (i >= cfg.grid.z) continue;
        float4 p = samples[i];
        if (p.w == 0 || (phase == 0 && p.w != 2) || (phase != 0 && p.w != 1)) continue;
        float base = cfg.grid.w ? r.base[group.y] : cfg.base[group.y];
        float value = phase == 2 ? -precise::log10(p[group.y] / max(base, 1e-6f)) : precise::log10(p[group.y]);
        float coordinate = phase == 2 ? (value + 1.0f) / 7.0f : (value + 6.0f) / logRange;
        uint b = uint(clamp(coordinate * float(bins), 0.0f, float(bins-1)));
        atomic_fetch_add_explicit(&histogram[b], 1, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint groups = (cfg.grid.z + 1023) / 1024;
    for (uint b = lane; b < bins; b += 256)
        partial[(group.y * groups + group.x) * bins + b] = atomic_load_explicit(&histogram[b], memory_order_relaxed);
}

kernel void negativeMeterMerge(device const uint *partial [[buffer(0)]], device uint *hist [[buffer(1)]],
    constant MeterConfig &cfg [[buffer(2)]], uint2 i [[thread_position_in_grid]]) {
    if (i.x >= bins || i.y >= 3) return;
    uint groups = (cfg.grid.z + 1023) / 1024, total = 0;
    for (uint g = 0; g < groups; ++g) total += partial[(i.y * groups + g) * bins + i.x];
    hist[i.y * bins + i.x] = total;
}

float quantile(device const uint *h, float q, thread uint &total) {
    total = 0;
    for (uint b = 0; b < bins; ++b) total += h[b];
    if (!total) return 0.0f;
    uint rank = max(1u, uint(ceil(q * float(total)))), sum = 0;
    for (uint b = 0; b < bins; ++b) {
        sum += h[b];
        if (sum >= rank) return (float(b) + 0.5f) / float(bins);
    }
    return 1.0f;
}

// One thread selects all channels. Component stores on a device float4 can
// lower to vector read/modify/write; parallel channel writes would race.
kernel void negativeMeterSelect(device const uint *hist [[buffer(0)]], device MeterResult &r [[buffer(1)]],
    constant MeterConfig &cfg [[buffer(2)]], constant uint &phase [[buffer(3)]],
    uint tid [[thread_position_in_grid]]) {
    if (tid) return;
    for (uint c = 0; c < 3; ++c) {
        uint count;
        device const uint *h = hist + c * bins;
        if (phase == 0) {
            if(r.base.w>0) { r.quality[c]=r.base.w; continue; }
            float median = quantile(h, 0.5f, count), bright = quantile(h, 0.9f, count);
            r.base[c] = precise::pow(10.0f, bright * logRange - 6.0f);
            // A flat bright border supports a base; scene-filled edges do not.
            r.quality[c] = count >= 16 ? clamp(1.0f - (bright - median) * logRange / 0.06f, 0.0f, 1.0f) : 0;
        } else if (phase == 1) {
            float bright = quantile(h, 0.995f, count);
            if (r.base.w == 0 && min(min(r.quality.x, r.quality.y), r.quality.z) < 0.5f)
                r.base[c] = precise::pow(10.0f, bright * logRange - 6.0f);
        } else {
            r.low[c] = quantile(h, 0.01f, count) * 7.0f - 1.0f;
            r.high[c] = max(r.low[c] + 0.01f, quantile(h, 0.99f, count) * 7.0f - 1.0f);
        }
    }
}

// Independent block moments in density space, gated against gross chromatic
// outliers using provisional percentile normalization. No image readback.
kernel void negativeMeterMoments(device const float4 *samples [[buffer(0)]], device float4 *moments [[buffer(1)]],
    device const MeterResult &r [[buffer(2)]], constant MeterConfig &cfg [[buffer(3)]],
    uint group [[thread_position_in_grid]]) {
    float4 a(0), b(0), d(0);
    float3 base = cfg.grid.w ? r.base.rgb : cfg.base.rgb;
    for (uint j = 0; j < 1024; ++j) {
        uint i = group * 1024 + j;
        if (i >= cfg.grid.z) break;
        float4 p = samples[i];
        d.y += p.w > 0 ? 1.0f : 0.0f;
        d.z += p.w == 2 ? 1.0f : 0.0f;
        if (p.w != 1) continue;
        float3 v = -precise::log10(p.rgb / base);
        float3 n = (v - r.low.rgb) / (r.high.rgb - r.low.rgb);
        if (any(v < -1) || any(v > 6)) d.w += 1;
        if (any(n < 0.1f) || any(n > 0.9f) || max(max(n.x,n.y),n.z)-min(min(n.x,n.y),n.z) > 0.12f) continue;
        a += float4(v, 1);
        b += float4(v.y*v.y, v.x*v.y, v.z*v.y, v.x*v.x);
        d.x += v.z*v.z;
    }
    moments[group*3] = a; moments[group*3+1] = b; moments[group*3+2] = d;
}

kernel void negativeMeterFit(device const float4 *moments [[buffer(0)]], device MeterResult &r [[buffer(1)]],
    constant MeterConfig &cfg [[buffer(2)]], uint tid [[thread_position_in_grid]]) {
    if (tid) return;
    float4 a(0), b(0), d(0);
    for (uint g = 0; g < (cfg.grid.z+1023)/1024; ++g) {
        a += moments[g*3]; b += moments[g*3+1]; d += moments[g*3+2];
    }
    float valid = d.y / float(cfg.grid.z);
    float borderSupport = clamp(d.z / max(1.0f, float(cfg.grid.z)*0.19f), 0.0f, 1.0f);
    r.base.w = max(r.base.w,min(min(r.quality.x,r.quality.y),r.quality.z) * borderSupport) * valid;
    r.low.w = valid * clamp((r.high.y-r.low.y)/0.5f,0.0f,1.0f) *
        clamp(1.0f-d.w/max(1.0f,d.y),0.0f,1.0f);
    // Uncertain automatic base limits confidence in all derived calibration.
    float baseTrust=cfg.grid.w ? r.base.w : (cfg.base.w>0 ? cfg.base.w:1.0f);
    r.low.w *= 0.25f + 0.75f * baseTrust;
    r.high.w = r.low.w;
    float n = max(1.0f, a.w), variance = b.x - a.y*a.y/n;
    float3 slope(1), offset(0);
    float confidence = 0;
    if (a.w >= 16 && variance > 0.001f) {
        slope = float3((b.y-a.x*a.y/n)/variance, 1, (b.z-a.z*a.y/n)/variance);
        offset = a.rgb/n - slope*a.y/n;
        float residual = max(0.0f, b.w-a.x*a.x/n-slope.x*slope.x*variance) +
            max(0.0f, d.x-a.z*a.z/n-slope.z*slope.z*variance);
        // Require sample support and useful density leverage. Residual is
        // relative to scene span: real grain is not a fixed 0.05 D failure.
        float rms=sqrt(residual/(2.0f*n));
        float relative=rms/max(0.1f,r.high.y-r.low.y);
        confidence = r.low.w * clamp(a.w/512.0f,0.0f,1.0f) *
            clamp(variance/n/0.01f,0.0f,1.0f) * exp(-0.5f*pow(relative/0.08f,2.0f));
        if (any(slope < 0.25f) || any(slope > 4.0f) || any(abs(offset) > 1.0f)) confidence = 0;
    }
    // Do not apply an unsupported axis. Confidence remains visible for review.
    r.offset = float4(confidence > 0.1f ? offset : float3(0), confidence);
    r.slope = float4(confidence > 0.1f ? slope : float3(1), 0);
    r.quality = float4(valid, borderSupport, d.w/max(1.0f,d.y), a.w);
    r.low.rgb = float3(r.low.y);
    r.high.rgb = float3(r.high.y);
}
