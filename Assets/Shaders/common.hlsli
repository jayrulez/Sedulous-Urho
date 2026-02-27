#ifndef COMMON_HLSLI
#define COMMON_HLSLI

// Common shader definitions shared across all 3D shaders.
// Matches CRepr structs in FrameUniforms.bf.
#pragma pack_matrix(row_major)

#define MAX_LIGHTS 4
#define MAX_CASCADES 4
#define LIGHT_DIRECTIONAL 0
#define LIGHT_POINT 1
#define LIGHT_SPOT 2
#define PI 3.14159265359

// ============================================================
// Bind Group 1: Per-Frame Uniforms (space1)
// ============================================================

struct LightData
{
    float4 PositionAndRange;       // xyz = position, w = range
    float4 DirectionAndSpotAngle;  // xyz = direction, w = cos(outer)
    float4 ColorAndIntensity;      // xyz = color, w = specular intensity
    float4 TypeAndParams;          // x = type, y = cos(inner), zw = unused
};

cbuffer FrameUniforms : register(b0, space1)
{
    float4x4 View;
    float4x4 Projection;
    float4x4 ViewProjection;
    float4 CameraPositionAndTime;  // xyz = pos, w = time
    float4 AmbientColor;
    float4 FogParams1;             // xyz = fog color, w = fog start
    float4 FogParams2;             // x = fog end, y = deltaTime, z = lightCount, w = unused
    LightData Lights[MAX_LIGHTS];
    // Shadow data (offset 512)
    float4x4 ShadowMatrix0;       // Cascade 0 view-projection
    float4x4 ShadowMatrix1;       // Cascade 1 view-projection
    float4x4 ShadowMatrix2;       // Cascade 2 view-projection
    float4x4 ShadowMatrix3;       // Cascade 3 view-projection
    float4 ShadowSplits;          // xyzw = cascade 0-3 far distances (view-space Z)
    float4 ShadowParams;          // x = numCascades, y = bias, z = 1/atlasSize, w = enabled
    float4 ShadowParams2;         // x = normalBias (texels), yzw = unused
    float4 ShadowTexelSizes;      // xyzw = per-cascade world-space texel sizes (0-3)
    float4 IBLParams;             // x = diffuseIntensity, y = specularIntensity, z = prefilteredMipCount, w = enabled
};

// Shadow atlas depth texture + comparison sampler (space1)
Texture2D ShadowAtlas : register(t0, space1);
SamplerComparisonState ShadowSampler : register(s0, space1);

// Lightmap atlas texture + sampler (space1)
#ifdef LIGHTMAPPED
Texture2D LightmapAtlas : register(t1, space1);
SamplerState LightmapSampler : register(s1, space1);
#endif

// IBL cubemaps + BRDF LUT (space1)
#ifdef IBL
TextureCube IrradianceCube : register(t2, space1);
TextureCube PrefilteredCube : register(t3, space1);
Texture2D BrdfLUT : register(t4, space1);
SamplerState IBLSampler : register(s2, space1);
#endif

// ============================================================
// Bind Group 2: Per-Object Uniforms (space2)
// ============================================================

#ifndef INSTANCED
cbuffer ObjectUniforms : register(b0, space2)
{
    float4x4 World;
    float4 LightmapScaleOffset; // xy = scale, zw = offset
};
#endif

// ============================================================
// Bind Group 3: Bone Matrices (space3) — Skinned meshes only
// ============================================================

#ifdef SKINNED
#define MAX_BONES 96

cbuffer BoneMatrices : register(b0, space3)
{
    float4x4 Bones[MAX_BONES];
};
#endif

// ============================================================
// Helper accessors
// ============================================================

float3 GetCameraPosition() { return CameraPositionAndTime.xyz; }
float GetTime() { return CameraPositionAndTime.w; }
float3 GetFogColor() { return FogParams1.xyz; }
float GetFogStart() { return FogParams1.w; }
float GetFogEnd() { return FogParams2.x; }
float GetDeltaTime() { return FogParams2.y; }
int GetLightCount() { return (int)FogParams2.z; }

// Linear fog factor (0 = no fog, 1 = full fog).
float ComputeFogFactor(float dist)
{
    float fogStart = GetFogStart();
    float fogEnd = GetFogEnd();
    if (fogEnd <= fogStart) return 0;
    return saturate((dist - fogStart) / (fogEnd - fogStart));
}

// Apply fog to a color.
float3 ApplyFog(float3 color, float dist)
{
    float fog = ComputeFogFactor(dist);
    return lerp(color, GetFogColor(), fog);
}

// ============================================================
// Shadow helpers
// ============================================================

int GetShadowCascadeCount() { return (int)ShadowParams.x; }
float GetShadowBias() { return ShadowParams.y; }
float GetShadowTexelSize() { return ShadowParams.z; }
bool IsShadowEnabled() { return ShadowParams.w > 0.5; }
float GetShadowNormalBias() { return ShadowParams2.x; }

// Returns the world-space texel size for the given cascade (for normal offset scaling).
float GetCascadeTexelSize(int cascadeIndex)
{
    if (cascadeIndex == 0) return ShadowTexelSizes.x;
    if (cascadeIndex == 1) return ShadowTexelSizes.y;
    if (cascadeIndex == 2) return ShadowTexelSizes.z;
    return ShadowTexelSizes.w;
}

// Returns the shadow cascade view-projection matrix for the given index.
float4x4 GetShadowMatrix(int cascadeIndex)
{
    if (cascadeIndex == 0) return ShadowMatrix0;
    if (cascadeIndex == 1) return ShadowMatrix1;
    if (cascadeIndex == 2) return ShadowMatrix2;
    return ShadowMatrix3;
}

// Selects the appropriate cascade for a given view-space depth.
int SelectCascade(float viewDepth)
{
    int cascadeCount = GetShadowCascadeCount();
    if (cascadeCount <= 1) return 0;
    if (viewDepth < ShadowSplits.x) return 0;
    if (cascadeCount <= 2 || viewDepth < ShadowSplits.y) return 1;
    if (cascadeCount <= 3 || viewDepth < ShadowSplits.z) return 2;
    return 3;
}

// Samples the shadow map with 5x5 PCF for smooth soft shadows.
float SampleShadowPCF(float3 shadowCoord, int cascadeIndex)
{
    float bias = GetShadowBias();
    float texelSize = GetShadowTexelSize();

    // Cascade atlas offset: each cascade occupies 1/N of the atlas horizontally
    int cascadeCount = max(GetShadowCascadeCount(), 1);
    float cascadeWidth = 1.0 / (float)cascadeCount;
    float atlasOffsetX = cascadeWidth * (float)cascadeIndex;

    // Map from [-1,1] clip space to [0,1] UV space
    float2 uv = shadowCoord.xy * 0.5 + 0.5;
    // Scale into cascade atlas region
    uv.x = atlasOffsetX + uv.x * cascadeWidth;

    float depth = saturate(shadowCoord.z) - bias;

    // 5x5 PCF for smooth shadow edges
    float shadow = 0;
    [unroll]
    for (int y = -2; y <= 2; y++)
    {
        [unroll]
        for (int x = -2; x <= 2; x++)
        {
            float2 offset = float2(x, y) * texelSize;
            shadow += ShadowAtlas.SampleCmpLevelZero(ShadowSampler, uv + offset, depth);
        }
    }
    return shadow / 25.0;
}

// Computes the shadow factor for a world-space position with normal offset bias.
// N = surface world normal, lightDir = normalized direction TO the light.
float ComputeShadowFactor(float3 worldPos, float3 N, float3 lightDir)
{
    if (!IsShadowEnabled())
        return 1.0;

    // Compute view-space depth for cascade selection.
    float4 viewPos = mul(float4(worldPos, 1.0), View);
    float viewDepth = -viewPos.z;
    int cascade = SelectCascade(viewDepth);

    // Normal offset bias: push sample position along surface normal to reduce acne.
    // Offset is larger when surface is nearly perpendicular to light (grazing angles).
    float NdotL = saturate(dot(N, lightDir));
    float normalBias = GetShadowNormalBias();
    float cascadeTexel = GetCascadeTexelSize(cascade);
    float3 offsetPos = worldPos + N * (normalBias * cascadeTexel * (1.0 - NdotL));

    // Transform to shadow clip space
    float4x4 shadowMat = GetShadowMatrix(cascade);
    float4 shadowClip = mul(float4(offsetPos, 1.0), shadowMat);
    float3 shadowCoord = shadowClip.xyz / shadowClip.w;

    // Out of shadow map bounds → fully lit
    if (any(shadowCoord.xy < -1.0) || any(shadowCoord.xy > 1.0) || shadowCoord.z < 0.0 || shadowCoord.z > 1.0)
        return 1.0;

    return SampleShadowPCF(shadowCoord, cascade);
}

// Overload without normal (for compatibility — no normal offset).
float ComputeShadowFactor(float3 worldPos)
{
    return ComputeShadowFactor(worldPos, float3(0, 1, 0), float3(0, 1, 0));
}

// ============================================================
// IBL helpers
// ============================================================

float GetIBLDiffuseIntensity() { return IBLParams.x; }
float GetIBLSpecularIntensity() { return IBLParams.y; }
float GetIBLMipCount() { return IBLParams.z; }
bool IsIBLEnabled() { return IBLParams.w > 0.5; }

#ifdef IBL
// Fresnel-Schlick with roughness for IBL ambient specular.
float3 FresnelSchlickRoughness(float cosTheta, float3 F0, float roughness)
{
    float3 maxR = float3(1.0 - roughness, 1.0 - roughness, 1.0 - roughness);
    return F0 + (max(maxR, F0) - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

// Computes IBL ambient (diffuse + specular) using split-sum approximation.
float3 ComputeIBLAmbient(float3 N, float3 V, float3 albedo, float metallic, float roughness, float3 F0, float ao)
{
    if (!IsIBLEnabled())
        return AmbientColor.rgb * albedo * ao;

    float NdotV = max(dot(N, V), 0.001);
    float3 R = reflect(-V, N);

    // Diffuse IBL: sample irradiance cubemap
    float3 irradiance = IrradianceCube.Sample(IBLSampler, N).rgb;
    float3 F = FresnelSchlickRoughness(NdotV, F0, roughness);
    float3 kD = (1.0 - F) * (1.0 - metallic);
    float3 diffuseIBL = kD * irradiance * albedo * GetIBLDiffuseIntensity();

    // Specular IBL: sample prefiltered cubemap at roughness mip + BRDF LUT
    float mipLevel = roughness * GetIBLMipCount();
    float3 prefilteredColor = PrefilteredCube.SampleLevel(IBLSampler, R, mipLevel).rgb;
    float2 brdf = BrdfLUT.Sample(IBLSampler, float2(NdotV, roughness)).rg;
    float3 specularIBL = prefilteredColor * (F * brdf.x + brdf.y) * GetIBLSpecularIntensity();

    return (diffuseIBL + specularIBL) * ao;
}
#endif

#endif // COMMON_HLSLI
