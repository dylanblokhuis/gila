
struct PushConstats
{
    uint frame_index;
    uint[3] padding;
}

[[vk::push_constant]] ConstantBuffer<PushConstats> push_constants;
[[vk::binding(3)]] RWTexture2D<float4> storage_images[];


[shader("compute")]
[numthreads(8,8,1)]
void computeMain(uint3 threadId : SV_DispatchThreadID)
{
    storage_images[0][int2(threadId.x, threadId.y)] = hashFrame(float2(threadId.x, threadId.y), push_constants.frame_index);
}

float4 hashFrame(float2 xy, uint frame_index)
{
    float4 color = float4(0, 0, 0, 1);
    float2 p = xy / 256.0;
    float2 uv = p;
    uv.x += frame_index / 256.0;
    uv.y += frame_index / 256.0;
    color = float4(uv, 0, 1);
    return color;
}