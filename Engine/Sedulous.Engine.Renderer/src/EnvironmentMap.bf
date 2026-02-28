using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// Image-Based Lighting environment map data.
///
/// Holds the three textures needed for split-sum PBR IBL:
/// - Irradiance cubemap (diffuse ambient)
/// - Prefiltered specular cubemap (specular ambient, mip = roughness)
/// - BRDF integration LUT (2D texture, shared across all environments)
///
/// Attach to a Zone to provide ambient lighting for drawables in that zone.
/// Multiple zones can use different EnvironmentMaps for varied local ambience.
///
[EngineComponent("Rendering")]
public class EnvironmentMap : Component
{
	// Irradiance cubemap for diffuse IBL (not owned — set by user or loaded from resource)
	private ITextureView mIrradianceMap;
	// Prefiltered specular cubemap for specular IBL (not owned)
	private ITextureView mPrefilteredMap;
	// BRDF integration LUT (not owned — typically shared global)
	private ITextureView mBrdfLUT;

	// Intensity multipliers
	private float mDiffuseIntensity = 1.0f;
	private float mSpecularIntensity = 1.0f;

	// Source cubemap for preprocessing (not owned)
	private ITextureView mSourceCubemap;

	// Prefiltered mip count (number of roughness levels)
	private int32 mPrefilteredMipCount = 5;

	// ===== Properties =====

	/// Irradiance cubemap for diffuse ambient lighting.
	/// Low-resolution cubemap storing pre-convolved diffuse irradiance.
	public ITextureView IrradianceMap
	{
		get => mIrradianceMap;
		set => mIrradianceMap = value;
	}

	/// Prefiltered specular cubemap for specular ambient.
	/// Each mip level corresponds to increasing roughness.
	public ITextureView PrefilteredMap
	{
		get => mPrefilteredMap;
		set => mPrefilteredMap = value;
	}

	/// BRDF integration lookup texture (2D).
	/// X = NdotV, Y = roughness, output = (scale, bias) for Fresnel.
	/// This is typically a single shared texture across all environment maps.
	public ITextureView BrdfLUT
	{
		get => mBrdfLUT;
		set => mBrdfLUT = value;
	}

	/// Intensity multiplier for diffuse IBL contribution.
	public float DiffuseIntensity
	{
		get => mDiffuseIntensity;
		set => mDiffuseIntensity = Math.Max(value, 0.0f);
	}

	/// Intensity multiplier for specular IBL contribution.
	public float SpecularIntensity
	{
		get => mSpecularIntensity;
		set => mSpecularIntensity = Math.Max(value, 0.0f);
	}

	/// Source cubemap from which irradiance and prefiltered maps are generated.
	public ITextureView SourceCubemap
	{
		get => mSourceCubemap;
		set => mSourceCubemap = value;
	}

	/// Number of mip levels in the prefiltered specular cubemap.
	public int32 PrefilteredMipCount
	{
		get => mPrefilteredMipCount;
		set => mPrefilteredMipCount = Math.Clamp(value, 1, 12);
	}

	/// Whether this environment map has all required textures for rendering.
	public bool IsReady => mIrradianceMap != null && mPrefilteredMap != null && mBrdfLUT != null;

	// ===== Methods =====

	/// Gets the IBL data as a struct for passing to shaders.
	public IBLData GetIBLData()
	{
		return .()
		{
			IrradianceMap = mIrradianceMap,
			PrefilteredMap = mPrefilteredMap,
			BrdfLUT = mBrdfLUT,
			DiffuseIntensity = mDiffuseIntensity,
			SpecularIntensity = mSpecularIntensity,
			PrefilteredMipCount = mPrefilteredMipCount
		};
	}

	/// Creates a BRDF integration LUT texture on the GPU.
	/// This is a one-time computation, shared across all environment maps.
	/// Resolution is typically 512x512.
	public static Result<ITexture> CreateBrdfLUT(IDevice device, int32 resolution = 512)
	{
		var desc = TextureDescriptor.Texture2D(
			(uint32)resolution, (uint32)resolution,
			.RG16Float,
			.RenderTarget | .Sampled
		);

		if (device.CreateTexture(&desc) case .Ok(let tex))
			return .Ok(tex);
		else
			return .Err;
	}

	/// Creates an irradiance cubemap texture.
	/// Irradiance maps are typically low resolution (32-64).
	public static Result<ITexture> CreateIrradianceCubemap(IDevice device, int32 resolution = 64)
	{
		var desc = TextureDescriptor.Cubemap(
			(uint32)resolution,
			.RGBA16Float,
			.RenderTarget | .Sampled | .CopyDst
		);

		if (device.CreateTexture(&desc) case .Ok(let tex))
			return .Ok(tex);
		else
			return .Err;
	}

	/// Creates a prefiltered specular cubemap texture with mip chain.
	/// Each mip level stores a different roughness level.
	public static Result<ITexture> CreatePrefilteredCubemap(IDevice device, int32 resolution = 256, int32 mipLevels = 5)
	{
		var desc = TextureDescriptor.Cubemap(
			(uint32)resolution,
			.RGBA16Float,
			.RenderTarget | .Sampled | .CopyDst,
			(uint32)mipLevels
		);

		if (device.CreateTexture(&desc) case .Ok(let tex))
			return .Ok(tex);
		else
			return .Err;
	}
}

/// IBL data bundle for shader consumption.
public struct IBLData
{
	public ITextureView IrradianceMap;
	public ITextureView PrefilteredMap;
	public ITextureView BrdfLUT;
	public float DiffuseIntensity;
	public float SpecularIntensity;
	public int32 PrefilteredMipCount;
}
