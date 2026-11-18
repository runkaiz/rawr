#include <metal_stdlib>
using namespace metal;

struct DustParameters { float4 controls; uint4 flags; };
constant int2 dustDirections[4] = {int2(1,0), int2(0,1), int2(1,1), int2(1,-1)};

static uint2 bounded(int2 p, texture2d<float, access::read> t) {
    return uint2(clamp(p, int2(0), int2(t.get_width()-1, t.get_height()-1)));
}
static float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float irValue(texture2d<float, access::read> t, int2 p) {
    float4 v = t.read(bounded(p, t));
    return v.r;
}

// A sparse, spatially averaged regression suppresses small defects in the fit.
// All sufficient statistics and the fitted ghost coefficient remain on GPU.
kernel void dustIRFit(texture2d<float, access::read> rgb [[texture(0)]],
                      texture2d<float, access::read> ir [[texture(1)]],
                      constant DustParameters &p [[buffer(0)]], device float4 &fit [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float sx=0, sy=0, sxx=0, sxy=0, n=0;
    for (int y=0; y<32; ++y) for (int x=0; x<32; ++x) {
        int2 q = int2((float2(x,y)+0.5f) * float2(rgb.get_width(),rgb.get_height()) / 32.0f);
        float a=0,b=0;
        for (int k=0; k<4; ++k) {
            int2 z=q+int2((k&1)*4-2,(k>>1)*4-2);
            a += luminance(rgb.read(bounded(z,rgb)).rgb)*0.25f;
            b += irValue(ir,z)*0.25f;
        }
        if (!isfinite(a) || !isfinite(b) || b<=0 || a<=0) continue;
        sx+=a; sy+=b; sxx+=a*a; sxy+=a*b; n+=1;
    }
    float variance=sxx-sx*sx/max(n,1.0f);
    float slope=variance>0.001f ? clamp((sxy-sx*sy/max(n,1.0f))/variance,-1.0f,1.0f) : 0;
    fit=float4(slope*p.controls.w,0,0,0);
}
kernel void dustIRCorrect(texture2d<float, access::read> rgb [[texture(0)]],
                          texture2d<float, access::read> ir [[texture(1)]],
                          texture2d<float, access::write> out [[texture(2)]],
                          device const float4 &fit [[buffer(1)]], constant uint4 &tile [[buffer(3)]],
                          uint2 q [[thread_position_in_grid]]) {
    uint2 sourcePoint=uint2(q.x,q.y+tile.x);
    float v=irValue(ir,int2(sourcePoint))-fit.x*(luminance(rgb.read(sourcePoint).rgb)-0.5f);
    out.write(float4(max(isfinite(v)?v:0.0f,0.00001f)),q);
}
// Separable closing reference: bridge dark occlusions without blurring the scan.
kernel void dustIRDilateX(texture2d<float, access::read> in [[texture(0)]],
                          texture2d<float, access::write> out [[texture(1)]],
                          constant DustParameters &p [[buffer(0)]], uint2 q [[thread_position_in_grid]]) {
    float v=0; int r=int(p.controls.y)*2+2;
    for(int x=-r;x<=r;++x) v=max(v,in.read(bounded(int2(q)+int2(x,0),in)).r);
    out.write(float4(v),q);
}
kernel void dustIRDilateY(texture2d<float, access::read> in [[texture(0)]],
                          texture2d<float, access::write> out [[texture(1)]],
                          constant DustParameters &p [[buffer(0)]], constant uint4 &tile [[buffer(3)]],
                          uint2 q [[thread_position_in_grid]]) {
    float v=0; int r=int(p.controls.y)*2+2;
    for(int y=-r;y<=r;++y) {
        uint row=uint(clamp(int(q.y)+y,0,int(tile.z)-1));
        v=max(v,in.read(uint2(q.x,row)).r);
    }
    out.write(float4(v),q);
}

// Opposing samples agree along an edge and disagree across it. Select the
// consensus of agreeing pairs so a single pair following a hair cannot win.
static float3 opticalReference(texture2d<float, access::read> image, int2 q, int radius,
                               thread float &noise) {
    float3 means[4]; float difference[4]; float best=1e10f;
    for(int k=0;k<4;++k) {
        int2 d=dustDirections[k]*radius;
        float3 a=image.read(bounded(q-d,image)).rgb, b=image.read(bounded(q+d,image)).rgb;
        means[k]=(a+b)*0.5f;
        difference[k]=length(a-b);
        best=min(best,difference[k]);
    }
    float levels[4]; int count=0;
    for(int k=0;k<4;++k) if(difference[k]<=best+0.06f) levels[count++]=luminance(means[k]);
    for(int a=1;a<count;++a) for(int b=a;b>0 && levels[b]<levels[b-1];--b) {
        float t=levels[b]; levels[b]=levels[b-1]; levels[b-1]=t;
    }
    float mid=levels[count/2];
    float3 sum=0; float weight=0;
    for(int k=0;k<4;++k) if(difference[k]<=best+0.06f) {
        float w=1.0f/(0.002f+abs(luminance(means[k])-mid));
        sum+=means[k]*w; weight+=w;
    }
    noise=best*0.5f;
    return sum/max(weight,1e-6f);
}

kernel void dustMask(texture2d<float, access::read> image [[texture(0)]],
                     texture2d<float, access::read> corrected [[texture(1)]],
                     texture2d<float, access::read> background [[texture(2)]],
                     texture2d<float, access::write> mask [[texture(3)]],
                     constant DustParameters &p [[buffer(0)]],
                     device const float4 *spots [[buffer(2)]], constant uint4 &tile [[buffer(3)]],
                     uint2 position [[thread_position_in_grid]]) {
    uint2 q=uint2(position.x,position.y+tile.y);
    uint2 samplePoint=uint2(q.x,q.y-tile.x);
    float score=0;
    if(p.flags.x) {
        // Average the dilated envelope to soften scanner noise in the reference.
        float base=0;
        for(int k=-2;k<=2;++k) base+=background.read(bounded(int2(samplePoint)+int2(k,0),background)).r*0.2f;
        float ratio=corrected.read(samplePoint).r/max(base,1e-5f);
        float threshold=mix(0.35f,0.04f,p.controls.x);
        score=smoothstep(threshold,threshold*1.6f,1-ratio);
    } else {
        float noise;
        float3 ref=opticalReference(image,int2(q),int(p.controls.y)+1,noise);
        float delta=abs(luminance(image.read(q).rgb-ref));
        float threshold=mix(0.24f,0.035f,p.controls.x)+noise*2;
        score=smoothstep(threshold,threshold*1.5f,delta);
    }
    float2 size=float2(image.get_width(),image.get_height());
    for(uint k=0;k<p.flags.y;++k) {
        float radius=max(1.0f,spots[k].z*min(size.x,size.y));
        float2 center=float2(spots[k].x,1-spots[k].y)*size;
        float distance=length(float2(q)+0.5f-center)/radius;
        score=max(score,1-smoothstep(0.65f,1.0f,distance));
    }
    mask.write(float4(score),q);
}

kernel void dustRepair(texture2d<float, access::read> image [[texture(0)]],
                       texture2d<float, access::read> mask [[texture(1)]],
                       texture2d<float, access::write> output [[texture(2)]],
                       texture2d<float, access::write> maskImage [[texture(3)]],
                       constant DustParameters &p [[buffer(0)]],
                       device const float4 *spots [[buffer(2)]], uint2 q [[thread_position_in_grid]]) {
    float amount=mask.read(q).r;
    if(p.flags.z) maskImage.write(float4(amount,amount,amount,1),q);
    float4 source=image.read(q);
    if(amount<=0) { output.write(source,q); return; }
    int radius=int(p.controls.y)+2;
    float2 size=float2(image.get_width(),image.get_height());
    for(uint k=0;k<p.flags.y;++k) {
        float r=spots[k].z*min(size.x,size.y);
        float2 center=float2(spots[k].x,1-spots[k].y)*size;
        if(length(float2(q)+0.5f-center)<r) radius=max(radius,int(ceil(r))+2);
    }
    float noise;
    float3 guide=opticalReference(image,int2(q),radius,noise);
    float3 sum=0; float weights=0; float3 grain=0; float best=1e20f;
    // Bounded directional normalized fill. Growing supports skip masked donors;
    // color agreement weights follow edges rather than averaging across them.
    for(int scale=1;scale<=3;++scale) for(int k=0;k<8;++k) {
        int2 direction=dustDirections[k/2]*(k%2 ? -1 : 1);
        int2 z=int2(q)+direction*(radius*scale);
        if(any(z<0)||z.x>=int(size.x)||z.y>=int(size.y)) continue;
        float clean=1-mask.read(uint2(z)).r;
        if(clean<0.9f) continue;
        float3 donor=image.read(uint2(z)).rgb;
        float difference=length(donor-guide);
        float w=clean/(0.0001f+difference*difference)*exp(-float(scale-1));
        sum+=w*donor; weights+=w;
        if(difference<best) {
            best=difference;
            float3 low=0;
            for(int j=0;j<4;++j) low+=image.read(bounded(z+dustDirections[j],image)).rgb*0.25f;
            grain=clamp(donor-low,-0.02f,0.02f);
        }
    }
    if(weights>0) {
        float3 repaired=sum/weights+grain*0.35f;
        source.rgb=mix(source.rgb,repaired,amount);
    }
    output.write(source,q);
}
