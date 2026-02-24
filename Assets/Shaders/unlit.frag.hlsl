// Unlit Fragment Shader
// Samples albedo texture, multiplies by base color, applies emissive and fog.
// No lighting calculations.
#include "common.hlsli"

// ============================================================
// Bind Group 0: Material Uniforms (space0)
// Layout matches Materials.CreateUnlit() in Materials.bf
// ============================================================

cbuffer MaterialUniforms : register(b0, space0)
{
    float4 BaseColor;       // offset 0
    float4 EmissiveColor;   // offset 16
    float AlphaCutoff;      // offset 32
};

Texture2D AlbedoMap       : register(t0, space0);
SamplerState MainSampler  : register(s0, space0);

// ============================================================
// Fragment Input
// ============================================================

struct PSInput
{
    float4 ClipPosition   : SV_Position;
    float2 TexCoord       : TEXCOORD0;
    float4 VertexColor    : COLOR0;
    float  CameraDistance  : TEXCOORD1;
};

// ============================================================
// Main
// ============================================================

float4 main(PSInput input) : SV_Target
{
    float4 texColor = AlbedoMap.Sample(MainSampler, input.TexCoord);
    float4 color = texColor * BaseColor;

#ifdef VERTEX_COLORS
    color *= input.VertexColor;
#endif

    float alpha = color.a;

#ifdef ALPHA_TEST
    if (alpha < AlphaCutoff)
        discard;
#endif

    // Emissive
    float3 finalColor = color.rgb + EmissiveColor.rgb;

    // Fog
    finalColor = ApplyFog(finalColor, input.CameraDistance);

    return float4(finalColor, alpha);
}
