// Fullscreen Triangle Vertex Shader
// Generates a fullscreen triangle from vertex ID (no vertex buffer needed).
// Used for all post-processing passes.
#pragma pack_matrix(row_major)

struct VSOutput
{
    float4 Position : SV_Position;
    float2 TexCoord : TEXCOORD0;
};

VSOutput main(uint vertexID : SV_VertexID)
{
    VSOutput output;

    // Generate fullscreen triangle from vertex ID
    // Vertex 0: (-1, -1), Vertex 1: (3, -1), Vertex 2: (-1, 3)
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    output.Position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    output.TexCoord = uv;
    return output;
}
