// Skybox Fragment Shader
// Samples a cubemap texture using the interpolated direction vector.
#include "common.hlsli"

// ============================================================
// Bind Group 0: Material (space0)
// Layout matches Materials.CreateSkybox() — cubemap + sampler, no uniforms
// ============================================================

TextureCube EnvironmentMap       : register(t0, space0);
SamplerState EnvironmentSampler  : register(s0, space0);

struct PSInput
{
    float4 ClipPosition : SV_Position;
    float3 TexCoord     : TEXCOORD0;
};

float4 main(PSInput input) : SV_Target
{
    float3 color = EnvironmentMap.Sample(EnvironmentSampler, input.TexCoord).rgb;
    return float4(color, 1.0);
}
