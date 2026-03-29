// Fused BGRA→RGB resize kernel with hardware texture sampling
// Compile: nvcc -ptx -o bgra_to_rgb_resize.ptx bgra_to_rgb_resize.cu

extern "C" __global__ void bgra_to_rgb_resize(
    cudaTextureObject_t src_tex,
    unsigned char* dst,
    int dst_width,
    int dst_height,
    size_t dst_pitch,
    float scale_x,
    float scale_y
) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    
    if (x >= dst_width || y >= dst_height) return;
    
    // Sample with hardware bilinear filtering
    // +0.5 for pixel center sampling
    float4 pixel = tex2D<float4>(src_tex, 
        (x + 0.5f) * scale_x, 
        (y + 0.5f) * scale_y);
    
    // BGRA → RGB conversion (texture returns normalized 0-1)
    unsigned char r = (unsigned char)(pixel.z * 255.0f + 0.5f);  // R from B channel
    unsigned char g = (unsigned char)(pixel.y * 255.0f + 0.5f);  // G
    unsigned char b = (unsigned char)(pixel.x * 255.0f + 0.5f);  // B from R channel
    
    // Write interleaved RGB (3 bytes per pixel)
    size_t dst_idx = y * dst_pitch + x * 3;
    dst[dst_idx + 0] = r;
    dst[dst_idx + 1] = g;
    dst[dst_idx + 2] = b;
}
