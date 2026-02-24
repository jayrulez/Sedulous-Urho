// Tone Mapping Fragment Shader
// Converts HDR scene color to LDR for display.
// Supports Reinhard, ACES filmic, and exposure-only modes.
#pragma pack_matrix(row_major)

cbuffer ToneMapUniforms : register(b0, space0)
{
    float Exposure;     // Exposure multiplier (default 1.0)
    float Gamma;        // Gamma correction (default 2.2)
    float Method;       // 0=None, 1=Reinhard, 2=ACES, 3=Exposure
    float _Pad;
};

Texture2D SceneColor   : register(t0, space0);
SamplerState LinearSampler : register(s0, space0);

struct PSInput
{
    float4 Position : SV_Position;
    float2 TexCoord : TEXCOORD0;
};

// Reinhard tone mapping
float3 TonemapReinhard(float3 color)
{
    return color / (color + 1.0);
}

// ACES filmic tone mapping (approximation by Krzysztof Narkowicz)
float3 TonemapACES(float3 color)
{
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));
}

float4 main(PSInput input) : SV_Target
{
    float3 hdr = SceneColor.Sample(LinearSampler, input.TexCoord).rgb;

    // Apply exposure
    hdr *= Exposure;

    // Apply tone mapping
    float3 ldr;
    int method = (int)Method;
    if (method == 1)
        ldr = TonemapReinhard(hdr);
    else if (method == 2)
        ldr = TonemapACES(hdr);
    else if (method == 3)
        ldr = hdr; // Exposure only (already applied)
    else
        ldr = hdr; // Pass-through

    // Gamma correction
    ldr = pow(max(ldr, 0.0), 1.0 / Gamma);

    return float4(ldr, 1.0);
}
