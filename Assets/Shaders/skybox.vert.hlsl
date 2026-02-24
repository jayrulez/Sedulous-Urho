// Skybox Vertex Shader
// Renders a unit cube at the camera position with depth = 1.0 (farthest).
// Vertex layout: PositionOnly (float3) = 12 bytes
#include "common.hlsli"

struct VSInput
{
    float3 Position : POSITION;
};

struct VSOutput
{
    float4 ClipPosition : SV_Position;
    float3 TexCoord     : TEXCOORD0;
};

VSOutput main(VSInput input)
{
    VSOutput output;

    // Use the vertex position as the cubemap sampling direction
    output.TexCoord = input.Position;

    // Remove translation from the view matrix so the skybox stays centered on the camera.
    // Keep only the rotation (upper-left 3x3).
    float4x4 rotView = View;
    rotView[3][0] = 0;
    rotView[3][1] = 0;
    rotView[3][2] = 0;

    float4 clipPos = mul(float4(input.Position, 1.0), mul(rotView, Projection));

    // Set z = w so depth = 1.0 after perspective divide (always at far plane).
    output.ClipPosition = clipPos.xyww;

    return output;
}
