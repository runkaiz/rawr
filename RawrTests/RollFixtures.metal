#include <metal_stdlib>
using namespace metal;

// Independent synthetic film: known base, layer axis, and scene density.
// Mode 1 = blank, 2 = clipped, 3 = extremely dense, 4 = alien base.
kernel void rollTestFixture(texture2d<float, access::write> image [[texture(0)]],
    constant float4 &config [[buffer(0)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x>=image.get_width() || xy.y>=image.get_height()) return;
    float2 uv=(float2(xy)+0.5f)/float2(image.get_width(),image.get_height());
    float2 edgeCoordinate=float2(xy)/float2(image.get_width(),image.get_height());
    bool edge=any(edgeCoordinate<0.05f) || any(edgeCoordinate>=0.95f);
    float g=0.4f+1.4f*uv.x+config.x;
    float3 density=float3(0.12f+1.1f*g,g,-0.05f+0.9f*g);
    if (config.y==1) density=float3(0);
    if (config.y==3) density+=3.0f;
    if (edge) density=float3(0);
    float3 base=config.y==4 ? float3(0.3f,0.15f,0.075f) : float3(0.8f,0.4f,0.2f);
    float3 transmission=base*pow(float3(10),-density);
    if (config.y==2) transmission=float3(1);
    image.write(float4(transmission,1),xy);
}
