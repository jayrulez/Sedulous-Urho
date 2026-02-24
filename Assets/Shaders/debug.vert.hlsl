// Debug Line Vertex Shader
// Transforms world-space line vertices by the camera's ViewProjection.
// Passes vertex color through for per-line coloring.
#pragma pack_matrix(row_major)

cbuffer FrameUniforms : register(b0, space1)
{
    float4x4 View;
    float4x4 Projection;
    float4x4 ViewProjection;
};

struct VSInput
{
    float3 Position : POSITION;
    float4 Color    : COLOR0;
};

struct VSOutput
{
    float4 ClipPosition : SV_Position;
    float4 Color        : COLOR0;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    output.ClipPosition = mul(float4(input.Position, 1.0), ViewProjection);
    output.Color = input.Color;
    return output;
}
