// Terrain Fragment Shader
// PBR lighting without tangent-based normal mapping.
// Uses the same material uniform layout as forward.frag.hlsl.
#include "common.hlsli"

// Material bindings (space0) — same layout as forward PBR
cbuffer MaterialUniforms : register(b0, space0)
{
    float4 BaseColor;       // offset 0
    float Metallic;         // offset 16
    float Roughness;        // offset 20
    float AO;               // offset 24
    float AlphaCutoff;      // offset 28
    float4 EmissiveColor;   // offset 32
};

Texture2D AlbedoMap             : register(t0, space0);
Texture2D NormalMap             : register(t1, space0);
Texture2D MetallicRoughnessMap  : register(t2, space0);
Texture2D OcclusionMap          : register(t3, space0);
Texture2D EmissiveMap           : register(t4, space0);
SamplerState MainSampler        : register(s0, space0);

struct PSInput
{
    float4 ClipPosition   : SV_Position;
    float3 WorldPosition  : TEXCOORD0;
    float3 WorldNormal    : TEXCOORD1;
    float2 TexCoord       : TEXCOORD2;
    float  CameraDistance  : TEXCOORD3;
};

// PBR helper functions (same as forward.frag.hlsl)
float DistributionGGX(float NdotH, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom + 0.0001);
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k + 0.0001);
}

float GeometrySmith(float NdotV, float NdotL, float roughness)
{
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

float ComputeAttenuation(float distance, float range)
{
    if (range <= 0) return 1.0;
    float d = distance / range;
    float d2 = d * d;
    float atten = saturate(1.0 - d2 * d2);
    return atten * atten / (distance * distance + 0.01);
}

float ComputeSpotFactor(float3 lightDir, float3 spotDirection, float cosOuter, float cosInner)
{
    float cosAngle = dot(-lightDir, spotDirection);
    return saturate((cosAngle - cosOuter) / (cosInner - cosOuter + 0.0001));
}

float3 ComputeLight(LightData light, float3 worldPos, float3 N, float3 V,
    float3 albedo, float metallic, float roughness, float3 F0)
{
    int lightType = (int)light.TypeAndParams.x;
    float3 lightColor = light.ColorAndIntensity.xyz;
    float specIntensity = light.ColorAndIntensity.w;

    float3 L;
    float attenuation = 1.0;

    if (lightType == LIGHT_DIRECTIONAL)
    {
        L = -normalize(light.DirectionAndSpotAngle.xyz);
    }
    else
    {
        float3 toLight = light.PositionAndRange.xyz - worldPos;
        float dist = length(toLight);
        L = toLight / (dist + 0.0001);
        attenuation = ComputeAttenuation(dist, light.PositionAndRange.w);

        if (lightType == LIGHT_SPOT)
        {
            float cosOuter = light.DirectionAndSpotAngle.w;
            float cosInner = light.TypeAndParams.y;
            float3 spotDir = normalize(light.DirectionAndSpotAngle.xyz);
            attenuation *= ComputeSpotFactor(L, spotDir, cosOuter, cosInner);
        }
    }

    float3 H = normalize(V + L);
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.001);
    float NdotH = max(dot(N, H), 0.0);
    float HdotV = max(dot(H, V), 0.0);

    float D = DistributionGGX(NdotH, roughness);
    float G = GeometrySmith(NdotV, NdotL, roughness);
    float3 F = FresnelSchlick(HdotV, F0);

    float3 numerator = D * G * F;
    float denominator = 4.0 * NdotV * NdotL + 0.0001;
    float3 specular = numerator / denominator * specIntensity;

    float3 kD = (1.0 - F) * (1.0 - metallic);
    float3 diffuse = kD * albedo / PI;

    return (diffuse + specular) * lightColor * NdotL * attenuation;
}

float4 main(PSInput input) : SV_Target
{
    // Sample material textures
    float4 albedoSample = AlbedoMap.Sample(MainSampler, input.TexCoord);
    float4 albedo4 = albedoSample * BaseColor;
    float3 albedo = albedo4.rgb;
    float alpha = albedo4.a;

    // Alpha test
#ifdef ALPHA_TEST
    if (alpha < AlphaCutoff)
        discard;
#endif

    // Metallic-roughness
    float4 mrSample = MetallicRoughnessMap.Sample(MainSampler, input.TexCoord);
    float metallic = saturate(mrSample.b * Metallic);
    float roughness = saturate(mrSample.g * Roughness);
    roughness = max(roughness, 0.04);

    float ao = OcclusionMap.Sample(MainSampler, input.TexCoord).r * AO;

    // Normal (geometry normal, no tangent-space mapping)
    float3 N = normalize(input.WorldNormal);
    float3 V = normalize(GetCameraPosition() - input.WorldPosition);

    float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedo, metallic);

    // Shadow
    float shadowFactor = ComputeShadowFactor(input.WorldPosition);

    // Accumulate lighting
    float3 Lo = float3(0, 0, 0);
    int lightCount = min(GetLightCount(), MAX_LIGHTS);
    for (int i = 0; i < lightCount; i++)
    {
        float3 lightContrib = ComputeLight(Lights[i], input.WorldPosition, N, V,
            albedo, metallic, roughness, F0);
        if (i == 0 && (int)Lights[i].TypeAndParams.x == LIGHT_DIRECTIONAL)
            lightContrib *= shadowFactor;
        Lo += lightContrib;
    }

    // Ambient
    float3 ambient = AmbientColor.rgb * albedo * ao;

    // Emissive
    float3 emissive = EmissiveMap.Sample(MainSampler, input.TexCoord).rgb * EmissiveColor.rgb;

    // Final color
    float3 color = ambient + Lo + emissive;

    // Fog
    color = ApplyFog(color, input.CameraDistance);

    return float4(color, alpha);
}
