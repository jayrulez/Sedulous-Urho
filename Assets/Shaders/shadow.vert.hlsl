// Shadow Depth Vertex Shader
// Renders depth only for shadow map generation.
// Supports SKINNED variant for animated models.
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

#ifdef SKINNED
#define MAX_BONES 96
cbuffer BoneMatrices : register(b0, space3)
{
    float4x4 Bones[MAX_BONES];
};
#endif

struct VSInput
{
    float3 Position : POSITION;
#ifdef SKINNED
    float3 Normal : NORMAL;
    float2 TexCoord : TEXCOORD0;
    uint32_t Color : COLOR0;
    float4 Tangent : TANGENT;
    uint4 BoneIndices : BLENDINDICES;
    float4 BoneWeights : BLENDWEIGHT;
#endif
};

struct VSOutput
{
    float4 ClipPosition : SV_Position;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float3 localPos = input.Position;

#ifdef SKINNED
    float4x4 skinMatrix =
        Bones[input.BoneIndices.x] * input.BoneWeights.x +
        Bones[input.BoneIndices.y] * input.BoneWeights.y +
        Bones[input.BoneIndices.z] * input.BoneWeights.z +
        Bones[input.BoneIndices.w] * input.BoneWeights.w;
    localPos = mul(float4(localPos, 1.0), skinMatrix).xyz;
#endif

    float4 worldPos = mul(float4(localPos, 1.0), World);
    output.ClipPosition = mul(worldPos, ViewProjection);
    return output;
}
