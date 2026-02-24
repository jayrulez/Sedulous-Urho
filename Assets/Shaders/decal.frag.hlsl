// Decal Fragment Shader
// Applies a decal texture with vertex color tinting and basic diffuse lighting.
// Alpha-blended onto the surface beneath.
#include "common.hlsli"

// Material bindings (space0)
cbuffer MaterialUniforms : register(b0, space0)
{
    float4 BaseColor;       // offset 0
    float Metallic;         // offset 16 (unused for decals)
    float Roughness;        // offset 20 (unused for decals)
    float AO;               // offset 24 (unused for decals)
    float AlphaCutoff;      // offset 28
    float4 EmissiveColor;   // offset 32 (unused for decals)
};

Texture2D AlbedoMap      : register(t0, space0);
SamplerState MainSampler : register(s0, space0);

struct PSInput
{
    float4 ClipPosition   : SV_Position;
    float3 WorldPosition  : TEXCOORD0;
    float3 WorldNormal    : TEXCOORD1;
    float2 TexCoord       : TEXCOORD2;
    float4 VertexColor    : COLOR0;
    float  CameraDistance  : TEXCOORD3;
};

float4 main(PSInput input) : SV_Target
{
    // Sample decal texture
    float4 texColor = AlbedoMap.Sample(MainSampler, input.TexCoord);
    float4 color = texColor * BaseColor * input.VertexColor;

    // Alpha test
#ifdef ALPHA_TEST
    if (color.a < AlphaCutoff)
        discard;
#endif

    // Simple diffuse lighting from the first directional light
    float3 N = normalize(input.WorldNormal);
    int lightCount = min(GetLightCount(), MAX_LIGHTS);
    float3 lighting = AmbientColor.rgb;

    for (int i = 0; i < lightCount; i++)
    {
        int lightType = (int)Lights[i].TypeAndParams.x;
        float3 lightColor = Lights[i].ColorAndIntensity.xyz;

        if (lightType == LIGHT_DIRECTIONAL)
        {
            float3 L = -normalize(Lights[i].DirectionAndSpotAngle.xyz);
            float NdotL = max(dot(N, L), 0.0);
            lighting += lightColor * NdotL;
        }
    }

    color.rgb *= lighting;

    // Apply fog
    color.rgb = ApplyFog(color.rgb, input.CameraDistance);

    return color;
}
