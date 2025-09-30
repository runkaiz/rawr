#include <metal_stdlib>
using namespace metal;

// MARK: - Copy (Pass-through)

kernel void copyTexture(
    texture2d<half, access::read> inputTexture [[texture(0)]],
    texture2d<half, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    half4 color = inputTexture.read(gid);
    outputTexture.write(color, gid);
}