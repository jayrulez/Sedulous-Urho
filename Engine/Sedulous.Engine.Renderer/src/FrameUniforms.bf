using System;
using Sedulous.Foundation.Mathematics;

namespace Sedulous.Engine.Renderer;

/// Rendering constants shared between CPU and shader code.
public static class RenderConstants
{
	/// Maximum number of lights passed to shaders per frame.
	public const int32 MAX_SHADER_LIGHTS = 4;

	/// Alignment for dynamic uniform buffer offsets (Vulkan minimum guarantee).
	public const uint32 OBJECT_UNIFORM_ALIGN = 256;

	/// Maximum number of drawable objects per frame.
	public const int32 MAX_OBJECTS_PER_FRAME = 2048;

	/// Maximum number of shadow cascades (matches shader MAX_CASCADES).
	public const int32 MAX_SHADOW_CASCADES = 4;

	/// Size of the per-frame uniform buffer in bytes.
	public const uint32 FRAME_UNIFORM_SIZE = 848;

	/// Size of a single per-object uniform entry in bytes.
	public const uint32 OBJECT_UNIFORM_SIZE = 80;
}

/// Per-light data for GPU upload.
/// Matches HLSL LightData struct in common.hlsli (64 bytes, std140).
[CRepr]
public struct LightUniformData
{
	/// xyz = world position, w = range (0 for directional).
	public Vector4 PositionAndRange;
	/// xyz = normalized direction, w = cos(outer spot angle).
	public Vector4 DirectionAndSpotAngle;
	/// xyz = color * brightness, w = specular intensity.
	public Vector4 ColorAndIntensity;
	/// x = light type (0=dir, 1=point, 2=spot), y = cos(inner spot angle), zw = unused.
	public Vector4 TypeAndParams;
}

/// Per-frame uniform data uploaded to the GPU each frame.
/// Matches HLSL FrameUniforms cbuffer in common.hlsli (512 bytes, std140).
/// Bound at bind group slot 1, binding 0.
[CRepr]
public struct FrameUniformData
{
	/// Camera view matrix (world → view).
	public Matrix View;                       // 64 bytes, offset 0
	/// Camera projection matrix (view → clip).
	public Matrix Projection;                // 64 bytes, offset 64
	/// Combined view-projection matrix.
	public Matrix ViewProjection;            // 64 bytes, offset 128
	/// xyz = camera world position, w = total elapsed time.
	public Vector4 CameraPositionAndTime;    // 16 bytes, offset 192
	/// Zone ambient color (RGBA).
	public Vector4 AmbientColor;             // 16 bytes, offset 208
	/// xyz = fog color, w = fog start distance.
	public Vector4 FogParams1;               // 16 bytes, offset 224
	/// x = fog end distance, y = delta time, z = light count (as float), w = unused.
	public Vector4 FogParams2;               // 16 bytes, offset 240
	/// Light array (up to MAX_SHADER_LIGHTS).
	public LightUniformData[RenderConstants.MAX_SHADER_LIGHTS] Lights; // 256 bytes, offset 256
	// --- Shadow data (288 bytes, offset 512) ---
	/// Shadow cascade view-projection matrices (world → shadow clip space).
	public Matrix ShadowMatrix0;             // 64 bytes, offset 512
	public Matrix ShadowMatrix1;             // 64 bytes, offset 576
	public Matrix ShadowMatrix2;             // 64 bytes, offset 640
	public Matrix ShadowMatrix3;             // 64 bytes, offset 704
	/// Cascade split distances (view-space Z). xyzw = cascade 0-3 far.
	public Vector4 ShadowSplits;             // 16 bytes, offset 768
	/// x = num cascades, y = shadow bias, z = 1/atlas size, w = shadow enabled (1 or 0).
	public Vector4 ShadowParams;             // 16 bytes, offset 784
	/// x = normal offset bias (texels), y = cascade0 world texel size, z = cascade1, w = cascade2.
	public Vector4 ShadowParams2;            // 16 bytes, offset 800
	/// Per-cascade world texel sizes for cascades 0-3 (used for normal offset scaling).
	public Vector4 ShadowTexelSizes;         // 16 bytes, offset 816
	/// IBL: x = diffuse intensity, y = specular intensity, z = prefiltered mip count, w = IBL enabled (1 or 0).
	public Vector4 IBLParams;                // 16 bytes, offset 832
	// Total: 848 bytes
}

/// Per-object uniform data uploaded to the GPU for each draw call.
/// Matches HLSL ObjectUniforms cbuffer in common.hlsli (80 bytes).
/// Bound at bind group slot 2, binding 0 (with dynamic offset).
[CRepr]
public struct ObjectUniformData
{
	/// Object world transform matrix.
	public Matrix World;                     // 64 bytes
	/// Lightmap UV transform: xy = scale, zw = offset. Zero when not lightmapped.
	public Vector4 LightmapScaleOffset;      // 16 bytes, offset 64
}
