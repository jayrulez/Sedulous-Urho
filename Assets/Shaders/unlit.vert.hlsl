// Unlit Vertex Shader
// Transforms mesh vertices to clip space. No lighting calculations.
// Vertex layout: Position(float3) + Normal(float3) + UV(float2) + Color(ubyte4) + Tangent(float3) = 48 bytes
#include "common.hlsli"

struct VSInput
{
    float3 Position : POSITION;
    float3 Normal   : NORMAL;
    float2 TexCoord : TEXCOORD0;
    float4 Color    : COLOR0;
    float3 Tangent  : TANGENT;
};

struct VSOutput
{
    float4 ClipPosition   : SV_Position;
    float2 TexCoord       : TEXCOORD0;
    float4 VertexColor    : COLOR0;
    float  CameraDistance  : TEXCOORD1;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    // Transform to world space then clip space
    float4 worldPos = mul(float4(input.Position, 1.0), World);
    output.ClipPosition = mul(worldPos, ViewProjection);

    // Pass through UV and vertex color
    output.TexCoord = input.TexCoord;
    output.VertexColor = input.Color;

    // Camera distance for fog
    output.CameraDistance = length(worldPos.xyz - GetCameraPosition());

    return output;
}
