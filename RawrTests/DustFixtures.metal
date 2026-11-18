#include <metal_stdlib>
using namespace metal;

kernel void dustBenchmarkFixture(texture2d<float, access::write> rgb [[texture(0)]],
                                 texture2d<float, access::write> ir [[texture(1)]],
                                 uint2 q [[thread_position_in_grid]]) {
    float v=q.x<rgb.get_width()/2 ? 0.3f : 0.7f;
    float grain=0.003f*sin(float(q.x*13+q.y*17));
    bool dust=(q.x%127==50 && q.y%131>=40 && q.y%131<47);
    rgb.write(float4(float3(dust ? 0.01f : v+grain),1),q);
    ir.write(float4(dust ? 0.1f : 0.8f+0.1f*v),q);
}
