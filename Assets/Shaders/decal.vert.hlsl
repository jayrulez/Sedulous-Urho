// Decal Vertex Shader
// Transforms decal quad vertices (already in world space) to clip space.
// Vertex layout: Position(float3) + Normal(float3) + UV(float2) + Color(ubyte4norm) = 36 bytes
#include "common.hlsli"

struct VSInput
{
    float3 Position : POSITION;
    float3 Normal   : NORMAL;
    float2 TexCoord : TEXCOORD0;
    float4 Color    : COLOR0;
};

struct VSOutput
{
    float4 ClipPosition   : SV_Position;
    float3 WorldPosition  : TEXCOORD0;
    float3 WorldNormal    : TEXCOORD1;
    float2 TexCoord       : TEXCOORD2;
    float4 VertexColor    : COLOR0;
    float  CameraDistance  : TEXCOORD3;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    // Decal vertices are already in world space (World = Identity)
    float4 worldPos = mul(float4(input.Position, 1.0), World);
    output.WorldPosition = worldPos.xyz;
    output.ClipPosition = mul(worldPos, ViewProjection);

    // Normal is already in world space
    output.WorldNormal = normalize(input.Normal);

    output.TexCoord = input.TexCoord;
    output.VertexColor = input.Color;
    output.CameraDistance = length(worldPos.xyz - GetCameraPosition());

    return output;
}
