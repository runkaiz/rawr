#include <metal_stdlib>
using namespace metal;
struct RollMeter { float4 base, low, high, offset, slope, quality; };

// Small roll-summary arrays are sorted on the GPU, never on the CPU. Insertion
// sort bounds temporary storage to O(frame count); no pixels leave the GPU.
float rollMedian(device float *values, uint n) {
    for (uint i=1; i<n; ++i) {
        float v=values[i]; uint j=i;
        while (j && values[j-1]>v) { values[j]=values[j-1]; --j; }
        values[j]=v;
    }
    return n ? (values[(n-1)/2]+values[n/2])*0.5f : 0;
}

// Separate optical reference from scene support. Compare chromaticity so a
// scanner's exposure gain is not mistaken for a different film mask.
kernel void negativeRollBase(device const RollMeter *input [[buffer(0)]],
    device float *scratch [[buffer(1)]], device uint *accepted [[buffer(2)]],
    device float4 &output [[buffer(3)]], constant uint &count [[buffer(4)]],
    uint tid [[thread_position_in_grid]]) {
    if(tid) return;
    uint candidates=0;
    for(uint i=0;i<count;++i) {
        float4 b=input[i].base;
        accepted[i]=all(isfinite(b)) && all(b.rgb>1e-6f) && b.w>=0.5f;
        candidates+=accepted[i];
    }
    float center[2],tolerance[2];
    for(uint c=0;c<2;++c) {
        uint n=0;
        for(uint i=0;i<count;++i) if(accepted[i])
            scratch[n++]=precise::log10(input[i].base[c==0 ? 0:2]/input[i].base.y);
        center[c]=rollMedian(scratch,n);
        for(uint i=0;i<n;++i) scratch[i]=abs(scratch[i]-center[c]);
        tolerance[c]=max(0.025f,4.4478f*rollMedian(scratch,n));
    }
    uint included=0;
    for(uint i=0;i<count;++i) if(accepted[i]) {
        float3 b=input[i].base.rgb;
        accepted[i]=abs(precise::log10(b.x/b.y)-center[0])<=tolerance[0] &&
            abs(precise::log10(b.z/b.y)-center[1])<=tolerance[1];
        included+=accepted[i];
    }
    output=float4(1,1,1,0);
    if(!included) return;
    float4 result(0);
    for(uint c=0;c<4;++c) {
        uint n=0;
        for(uint i=0;i<count;++i) if(accepted[i]) {
            float4 b=input[i].base;
            scratch[n++]=c==0 ? b.x/b.y : (c==2 ? b.z/b.y:b[c]);
        }
        result[c]=rollMedian(scratch,n);
    }
    result.xz*=result.y;
    result.w*=float(included)/float(max(1u,candidates));
    output=result;
}

kernel void negativeRollReduce(device const RollMeter *input [[buffer(0)]],
    device float *scratch [[buffer(1)]], device float4 *frames [[buffer(2)]],
    device RollMeter &output [[buffer(3)]], constant uint &count [[buffer(4)]],
    uint tid [[thread_position_in_grid]]) {
    if (tid) return;
    uint candidates=0;
    for (uint i=0; i<count; ++i) {
        RollMeter r=input[i];
        bool ok=all(isfinite(r.base)) && all(isfinite(r.low)) && all(isfinite(r.high)) &&
            all(isfinite(r.offset)) && all(isfinite(r.slope)) &&
            r.base.w>=0.5f && r.low.w>=0.5f &&
            r.quality.x>=0.8f && r.quality.z<0.1f && r.high.y-r.low.y>=0.2f;
        frames[i]=float4(ok ? 1.0f : 0.0f,0,0,0);
        candidates+=ok;
    }
    // Reject inconsistent base, density span and extreme exposure using median
    // absolute deviations. Floors reflect histogram quantization and allow
    // ordinary exposure variation. Freeze all thresholds before rejecting.
    float center[5], tolerance[5];
    for (uint axis=0; axis<5; ++axis) {
        uint n=0;
        for (uint i=0; i<count; ++i) if (frames[i].x>0) {
            RollMeter r=input[i];
            scratch[n++]=axis<3 ? precise::log10(r.base[axis]) :
                (axis==3 ? r.high.y-r.low.y : (r.high.y+r.low.y)*0.5f);
        }
        center[axis]=rollMedian(scratch,n);
        for (uint i=0; i<n; ++i) scratch[i]=abs(scratch[i]-center[axis]);
        tolerance[axis]=max(axis<3 ? 0.04f : (axis==3 ? 0.3f : 0.6f),4.4478f*rollMedian(scratch,n));
    }
    uint included=0;
    for (uint i=0; i<count; ++i) if (frames[i].x>0) {
        RollMeter r=input[i]; bool ok=true;
        for (uint axis=0; axis<5; ++axis) {
            float v=axis<3 ? precise::log10(r.base[axis]) :
                (axis==3 ? r.high.y-r.low.y : (r.high.y+r.low.y)*0.5f);
            ok=ok && abs(v-center[axis])<=tolerance[axis];
        }
        frames[i].x=ok ? 1 : 0; included+=ok;
    }
    RollMeter result={float4(1,1,1,0),float4(0),float4(2,2,2,0),float4(0),float4(1,1,1,0),float4(0)};
    // A single frame is not a roll baseline. Preserve a zero confidence result.
    if (included>=3) {
        uint balanceCount=0;
        for(uint i=0;i<count;++i) if(frames[i].x>0 && input[i].offset.w>=0.5f) ++balanceCount;
        for (uint field=0; field<5; ++field) for (uint c=0; c<4; ++c) {
            if(field>=3 && balanceCount<3) continue;
            uint n=0;
            for (uint i=0; i<count; ++i) if (frames[i].x>0) {
                RollMeter r=input[i];
                if(field>=3 && r.offset.w<0.5f) continue;
                float4 v=field==0 ? r.base : (field==1 ? r.low : (field==2 ? r.high : (field==3 ? r.offset : r.slope)));
                scratch[n++]=v[c];
            }
            float median=rollMedian(scratch,n);
            if (field==0) result.base[c]=median;
            else if (field==1) result.low[c]=median;
            else if (field==2) result.high[c]=median;
            else if (field==3) result.offset[c]=median;
            else result.slope[c]=median;
        }
        float support=float(included)/float(count);
        result.base.w*=support; result.low.w*=support; result.high.w*=support;
        result.offset.w*=float(balanceCount)/float(count);
        for (uint i=0; i<count; ++i) if (frames[i].x>0)
            frames[i].y=(input[i].low.y+input[i].high.y-result.low.y-result.high.y)*0.5f;
    }
    result.quality=float4(float(included),float(count),float(candidates),0);
    output=result;
}
