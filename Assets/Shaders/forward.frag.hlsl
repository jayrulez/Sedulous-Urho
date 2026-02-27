// PBR Forward Fragment Shader
// Cook-Torrance BRDF with GGX distribution, Smith-Schlick geometry, Fresnel-Schlick.
// Supports directional, point, and spot lights with distance attenuation.
#include "common.hlsli"

// ============================================================
// Bind Group 0: Material Uniforms (space0)
// Layout matches Materials.CreatePBR() in Materials.bf
// ============================================================

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

// ============================================================
// Fragment Input
// ============================================================

struct PSInput
{
    float4 ClipPosition   : SV_Position;
    float3 WorldPosition  : TEXCOORD0;
    float3 WorldNormal    : TEXCOORD1;
    float2 TexCoord       : TEXCOORD2;
    float4 VertexColor    : COLOR0;
    float3 WorldTangent   : TEXCOORD3;
    float  CameraDistance  : TEXCOORD4;
};

// ============================================================
// PBR Functions
// ============================================================

// GGX/Trowbridge-Reitz Normal Distribution Function
float DistributionGGX(float NdotH, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom + 0.0001);
}

// Smith-Schlick GGX Geometry Function (single direction)
float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k + 0.0001);
}

// Smith's method for combined geometry obstruction
float GeometrySmith(float NdotV, float NdotL, float roughness)
{
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

// Fresnel-Schlick approximation
float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

// ============================================================
// Lighting
// ============================================================

// Compute attenuation for point/spot lights
float ComputeAttenuation(float distance, float range)
{
    if (range <= 0) return 1.0; // Directional
    float d = distance / range;
    float d2 = d * d;
    float atten = saturate(1.0 - d2 * d2);
    return atten * atten / (distance * distance + 0.01);
}

// Compute spot light cone factor
float ComputeSpotFactor(float3 lightDir, float3 spotDirection, float cosOuter, float cosInner)
{
    float cosAngle = dot(-lightDir, spotDirection);
    return saturate((cosAngle - cosOuter) / (cosInner - cosOuter + 0.0001));
}

// Compute lighting contribution from a single light
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

        // Spot cone
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

    // Cook-Torrance specular BRDF
    float D = DistributionGGX(NdotH, roughness);
    float G = GeometrySmith(NdotV, NdotL, roughness);
    float3 F = FresnelSchlick(HdotV, F0);

    float3 numerator = D * G * F;
    float denominator = 4.0 * NdotV * NdotL + 0.0001;
    float3 specular = numerator / denominator * specIntensity;

    // Energy conservation: diffuse = (1 - specular) * (1 - metallic)
    float3 kD = (1.0 - F) * (1.0 - metallic);
    float3 diffuse = kD * albedo / PI;

    return (diffuse + specular) * lightColor * NdotL * attenuation;
}

// ============================================================
// Normal Mapping
// ============================================================

float3 GetWorldNormal(PSInput input)
{
#ifdef NORMAL_MAP
    float3 N = normalize(input.WorldNormal);
    float3 T = normalize(input.WorldTangent);
    // Re-orthogonalize tangent with Gram-Schmidt
    T = normalize(T - dot(T, N) * N);
    float3 B = cross(N, T);
    float3x3 TBN = float3x3(T, B, N);

    float3 tangentNormal = NormalMap.Sample(MainSampler, input.TexCoord).xyz;
    tangentNormal = tangentNormal * 2.0 - 1.0;
    return normalize(mul(tangentNormal, TBN));
#else
    return normalize(input.WorldNormal);
#endif
}

// ============================================================
// Main
// ============================================================

float4 main(PSInput input) : SV_Target
{
    // Sample material textures
    float4 albedoSample = AlbedoMap.Sample(MainSampler, input.TexCoord);
    float4 albedo4 = albedoSample * BaseColor;

#ifdef VERTEX_COLORS
    albedo4 *= input.VertexColor;
#endif

    float3 albedo = albedo4.rgb;
    float alpha = albedo4.a;

    // Alpha test
#ifdef ALPHA_TEST
    if (alpha < AlphaCutoff)
        discard;
#endif

    // Sample metallic-roughness (green = roughness, blue = metallic — glTF convention)
    float4 mrSample = MetallicRoughnessMap.Sample(MainSampler, input.TexCoord);
    float metallic = saturate(mrSample.b * Metallic);
    float roughness = saturate(mrSample.g * Roughness);
    roughness = max(roughness, 0.04); // Prevent zero roughness artifacts

    // Sample AO
    float ao = OcclusionMap.Sample(MainSampler, input.TexCoord).r * AO;

    // Normal
    float3 N = GetWorldNormal(input);
    float3 V = normalize(GetCameraPosition() - input.WorldPosition);

    // F0: reflectance at normal incidence
    // Non-metals: 0.04, metals: albedo color
    float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedo, metallic);

    // Light count (used for shadows and lighting loop)
    int lightCount = min(GetLightCount(), MAX_LIGHTS);

    // Shadow factor with normal offset bias (applied to first directional light)
    // Use first light's direction for normal offset if it's directional
    float3 shadowLightDir = float3(0, 1, 0);
    if (lightCount > 0 && (int)Lights[0].TypeAndParams.x == LIGHT_DIRECTIONAL)
        shadowLightDir = -normalize(Lights[0].DirectionAndSpotAngle.xyz);
    float shadowFactor = ComputeShadowFactor(input.WorldPosition, N, shadowLightDir);

    // Accumulate lighting
    float3 Lo = float3(0, 0, 0);
    for (int i = 0; i < lightCount; i++)
    {
        float3 lightContrib = ComputeLight(Lights[i], input.WorldPosition, N, V,
            albedo, metallic, roughness, F0);
        // Apply shadow to the first directional light
        if (i == 0 && (int)Lights[i].TypeAndParams.x == LIGHT_DIRECTIONAL)
            lightContrib *= shadowFactor;
        Lo += lightContrib;
    }

    // Ambient lighting — not affected by shadow
#ifdef LIGHTMAPPED
    // Sample baked lightmap using UV * scale + offset
    float2 lightmapUV = input.TexCoord * LightmapScaleOffset.xy + LightmapScaleOffset.zw;
    float3 lightmapColor = LightmapAtlas.Sample(LightmapSampler, lightmapUV).rgb;
    float3 ambient = lightmapColor * albedo * ao;
#elif defined(IBL)
    // Image-Based Lighting for ambient
    float3 ambient = ComputeIBLAmbient(N, V, albedo, metallic, roughness, F0, ao);
#else
    float3 ambient = AmbientColor.rgb * albedo * ao;
#endif

    // Emissive
    float3 emissive = EmissiveMap.Sample(MainSampler, input.TexCoord).rgb * EmissiveColor.rgb;

    // Final color
    float3 color = ambient + Lo + emissive;

    // Fog
    color = ApplyFog(color, input.CameraDistance);

    return float4(color, alpha);
}
