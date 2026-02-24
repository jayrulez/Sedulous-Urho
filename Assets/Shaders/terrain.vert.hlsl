// Terrain Vertex Shader
// Transforms terrain vertices (Position + Normal + UV = 32 bytes) to clip space.
// Simplified variant of forward.vert.hlsl without Color or Tangent attributes.
#include "common.hlsli"

struct VSInput
{
    float3 Position : POSITION;
    float3 Normal   : NORMAL;
    float2 TexCoord : TEXCOORD0;
};

struct VSOutput
{
    float4 ClipPosition   : SV_Position;
    float3 WorldPosition  : TEXCOORD0;
    float3 WorldNormal    : TEXCOORD1;
    float2 TexCoord       : TEXCOORD2;
    float  CameraDistance  : TEXCOORD3;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    // Transform to world space
    float4 worldPos = mul(float4(input.Position, 1.0), World);
    output.WorldPosition = worldPos.xyz;

    // Transform to clip space
    output.ClipPosition = mul(worldPos, ViewProjection);

    // Transform normal to world space
    float3x3 worldMatrix3 = (float3x3)World;
    output.WorldNormal = normalize(mul(input.Normal, worldMatrix3));

    output.TexCoord = input.TexCoord;

    // Camera distance for fog
    output.CameraDistance = length(worldPos.xyz - GetCameraPosition());

    return output;
}
