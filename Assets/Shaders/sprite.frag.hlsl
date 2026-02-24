// Sprite Fragment Shader
// Samples texture and multiplies with vertex color. Supports fog.
#include "common.hlsli"

// ============================================================
// Bind Group 0: Material (space0)
// Layout matches Materials.CreateSprite() — texture + sampler, no uniforms
// ============================================================

Texture2D SpriteTexture      : register(t0, space0);
SamplerState SpriteSampler   : register(s0, space0);

struct PSInput
{
    float4 ClipPosition  : SV_Position;
    float2 TexCoord      : TEXCOORD0;
    float4 VertexColor   : COLOR0;
    float  CameraDistance : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target
{
    float4 texColor = SpriteTexture.Sample(SpriteSampler, input.TexCoord);
    float4 color = texColor * input.VertexColor;

    // Discard fully transparent pixels
    if (color.a < 0.001)
        discard;

    // Apply fog
    color.rgb = ApplyFog(color.rgb, input.CameraDistance);

    return color;
}
