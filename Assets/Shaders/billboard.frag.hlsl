// Billboard/Particle Fragment Shader
// Samples the texture map and multiplies by vertex color.
// Applies fog based on camera distance.
#include "common.hlsli"

// Material bindings (space0)
Texture2D AlbedoMap      : register(t0, space0);
SamplerState MainSampler : register(s0, space0);

struct PSInput
{
    float4 ClipPosition  : SV_Position;
    float2 TexCoord      : TEXCOORD0;
    float4 VertexColor   : COLOR0;
    float  CameraDistance : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    float4 texColor = AlbedoMap.Sample(MainSampler, input.TexCoord);
    float4 color = texColor * input.VertexColor;

    // Apply fog
    color.rgb = ApplyFog(color.rgb, input.CameraDistance);

    return color;
}
