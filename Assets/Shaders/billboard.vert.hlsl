// Billboard/Particle Vertex Shader
// Transforms pre-built quad vertices (already in world space) to clip space.
// Vertex layout: Position(float3) + UV(float2) + Color(ubyte4norm) = 24 bytes
#include "common.hlsli"

struct VSInput
{
    float3 Position : POSITION;
    float2 TexCoord : TEXCOORD0;
    float4 Color    : COLOR0;
};

struct VSOutput
{
    float4 ClipPosition  : SV_Position;
    float2 TexCoord      : TEXCOORD0;
    float4 VertexColor   : COLOR0;
    float  CameraDistance : TEXCOORD1;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    // Billboard vertices are already in world space (World = Identity)
    float4 worldPos = mul(float4(input.Position, 1.0), World);
    output.ClipPosition = mul(worldPos, ViewProjection);

    output.TexCoord = input.TexCoord;
    output.VertexColor = input.Color;
    output.CameraDistance = length(worldPos.xyz - GetCameraPosition());

    return output;
}
