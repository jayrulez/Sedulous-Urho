// PBR Forward Vertex Shader
// Transforms mesh vertices to clip space and passes world-space data to the fragment shader.
// Vertex layout: Position(float3) + Normal(float3) + UV(float2) + Color(ubyte4) + Tangent(float3) = 48 bytes
// SKINNED variant adds: JointIndices(ushort4→uint4) + JointWeights(float4) = 72 bytes
// INSTANCED variant reads world matrix from instance buffer (4 x float4) instead of per-object UBO
#include "common.hlsli"

struct VSInput
{
    float3 Position : POSITION;
    float3 Normal   : NORMAL;
    float2 TexCoord : TEXCOORD0;
    float4 Color    : COLOR0;
    float3 Tangent  : TANGENT;
#ifdef SKINNED
    uint4  JointIndices : BLENDINDICES;
    float4 JointWeights : BLENDWEIGHT;
#endif
#ifdef INSTANCED
    float4 InstanceWorld0 : TEXCOORD5;
    float4 InstanceWorld1 : TEXCOORD6;
    float4 InstanceWorld2 : TEXCOORD7;
    float4 InstanceWorld3 : TEXCOORD8;
#endif
};

struct VSOutput
{
    float4 ClipPosition   : SV_Position;
    float3 WorldPosition  : TEXCOORD0;
    float3 WorldNormal    : TEXCOORD1;
    float2 TexCoord       : TEXCOORD2;
    float4 VertexColor    : COLOR0;
    float3 WorldTangent   : TEXCOORD3;
    float  CameraDistance  : TEXCOORD4;
};

VSOutput main(VSInput input)
{
    VSOutput output;

#ifdef INSTANCED
    // Build world matrix from instance buffer attributes
    float4x4 World = float4x4(
        input.InstanceWorld0,
        input.InstanceWorld1,
        input.InstanceWorld2,
        input.InstanceWorld3
    );
#endif

#ifdef SKINNED
    // Compute skinned position in model space using bone matrices
    float4x4 skinMatrix =
        Bones[input.JointIndices.x] * input.JointWeights.x +
        Bones[input.JointIndices.y] * input.JointWeights.y +
        Bones[input.JointIndices.z] * input.JointWeights.z +
        Bones[input.JointIndices.w] * input.JointWeights.w;

    float4 skinnedPos = mul(float4(input.Position, 1.0), skinMatrix);
    float4 worldPos = mul(skinnedPos, World);

    // Transform normal and tangent through skin + world
    float3x3 skinMatrix3 = (float3x3)skinMatrix;
    float3x3 worldMatrix3 = (float3x3)World;
    output.WorldNormal = normalize(mul(mul(input.Normal, skinMatrix3), worldMatrix3));
    output.WorldTangent = normalize(mul(mul(input.Tangent, skinMatrix3), worldMatrix3));
#else
    // Transform to world space
    float4 worldPos = mul(float4(input.Position, 1.0), World);

    // Transform normal and tangent to world space
    // Using (float3x3)World assumes uniform scale; normalize to handle slight non-uniformity.
    float3x3 worldMatrix3 = (float3x3)World;
    output.WorldNormal = normalize(mul(input.Normal, worldMatrix3));
    output.WorldTangent = normalize(mul(input.Tangent, worldMatrix3));
#endif

    output.WorldPosition = worldPos.xyz;

    // Transform to clip space
    output.ClipPosition = mul(worldPos, ViewProjection);

    // Pass through UV and vertex color
    output.TexCoord = input.TexCoord;
    output.VertexColor = input.Color;

    // Camera distance for fog
    output.CameraDistance = length(worldPos.xyz - GetCameraPosition());

    return output;
}
