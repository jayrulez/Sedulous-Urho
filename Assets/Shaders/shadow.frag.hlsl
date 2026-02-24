// Shadow Depth Fragment Shader
// For depth-only pipelines (DepthOnly = true), this shader isn't used.
// Required so the shader system can load the shader pair.
// When ALPHA_TEST is defined, performs alpha cutoff to avoid casting
// shadows from transparent areas.
#pragma pack_matrix(row_major)

#ifdef ALPHA_TEST
cbuffer MaterialUniforms : register(b0, space0)
{
    float4 BaseColor;
    float Metallic;
    float Roughness;
    float AO;
    float AlphaCutoff;
};

Texture2D AlbedoMap          : register(t0, space0);
SamplerState MainSampler     : register(s0, space0);
#endif

struct PSInput
{
    float4 ClipPosition : SV_Position;
#ifdef ALPHA_TEST
    float2 TexCoord     : TEXCOORD0;
#endif
};

void main(PSInput input)
{
#ifdef ALPHA_TEST
    float alpha = AlbedoMap.Sample(MainSampler, input.TexCoord).a * BaseColor.a;
    if (alpha < AlphaCutoff)
        discard;
#endif
}
