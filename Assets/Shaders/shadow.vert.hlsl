// Shadow Depth Vertex Shader
// Renders depth only for shadow map generation.
// Declares only the cbuffers it needs (no common.hlsli) to keep
// SPIRV bindings minimal for the shadow-specific pipeline layout.
#pragma pack_matrix(row_major)

// Per-frame uniforms (space1) — only View/Projection/ViewProjection used.
// During shadow passes, ViewProjection is the light's VP for the current cascade.
cbuffer FrameUniforms : register(b0, space1)
{
    float4x4 View;
    float4x4 Projection;
    float4x4 ViewProjection;
};

// Per-object uniforms (space2)
cbuffer ObjectUniforms : register(b0, space2)
{
    float4x4 World;
};

struct VSInput
{
    float3 Position : POSITION;
};

struct VSOutput
{
    float4 ClipPosition : SV_Position;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float4 worldPos = mul(float4(input.Position, 1.0), World);
    output.ClipPosition = mul(worldPos, ViewProjection);
    return output;
}
