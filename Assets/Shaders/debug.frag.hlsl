// Debug Line Fragment Shader
// Outputs the interpolated vertex color directly.

struct PSInput
{
    float4 ClipPosition : SV_Position;
    float4 Color        : COLOR0;
};

float4 main(PSInput input) : SV_Target0
{
    return input.Color;
}
