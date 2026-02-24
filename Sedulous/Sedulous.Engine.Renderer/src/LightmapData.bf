using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// Lightmap quality setting controlling bake resolution.
public enum LightmapQuality
{
	/// 64 texels per unit.
	Low,
	/// 128 texels per unit.
	Medium,
	/// 256 texels per unit.
	High,
	/// 512 texels per unit.
	Ultra
}

/// A single lightmap texture in the atlas.
public struct LightmapTexture
{
	/// The GPU texture containing baked lighting data.
	public ITextureView TextureView;
	/// Width of the lightmap texture.
	public int32 Width;
	/// Height of the lightmap texture.
	public int32 Height;
}

/// Per-object lightmap assignment.
public struct LightmapInfo
{
	/// Index into the lightmap atlas (-1 = no lightmap).
	public int32 LightmapIndex = -1;
	/// UV scale for mapping the object's lightmap UVs into the atlas.
	public Vector4 ScaleOffset = .(1, 1, 0, 0); // (scaleU, scaleV, offsetU, offsetV)
}

/// Manages baked lightmap textures for static geometry.
///
/// Provides an atlas of lightmap textures that static objects reference
/// via a lightmap index and UV scale/offset. Objects must have a second
/// UV set (UV2) with non-overlapping lightmap coordinates.
///
/// Usage:
///   let lightmaps = new LightmapManager();
///   let idx = lightmaps.AddLightmap(textureView, 1024, 1024);
///   staticModel.LightmapInfo = .(idx, .(1, 1, 0, 0));
///
[EngineComponent("Rendering")]
public class LightmapManager : Component
{
	private List<LightmapTexture> mLightmaps = new .() ~ delete _;
	private LightmapQuality mQuality = .Medium;
	private bool mLightmapEnabled = true;

	// ===== Properties =====

	/// Whether lightmapping is enabled for rendering.
	public bool LightmapEnabled
	{
		get => mLightmapEnabled;
		set => mLightmapEnabled = value;
	}

	/// Bake quality setting.
	public LightmapQuality Quality
	{
		get => mQuality;
		set => mQuality = value;
	}

	/// Number of lightmap textures in the atlas.
	public int32 LightmapCount => (int32)mLightmaps.Count;

	/// Gets the texels-per-unit for the current quality setting.
	public int32 TexelsPerUnit
	{
		get
		{
			switch (mQuality)
			{
			case .Low: return 64;
			case .Medium: return 128;
			case .High: return 256;
			case .Ultra: return 512;
			}
		}
	}

	// ===== Lightmap Atlas Management =====

	/// Adds a lightmap texture to the atlas. Returns the lightmap index.
	public int32 AddLightmap(ITextureView textureView, int32 width, int32 height)
	{
		let idx = (int32)mLightmaps.Count;
		mLightmaps.Add(.()
		{
			TextureView = textureView,
			Width = width,
			Height = height
		});
		return idx;
	}

	/// Gets the lightmap texture at the given index.
	public LightmapTexture GetLightmap(int32 index)
	{
		if (index >= 0 && index < mLightmaps.Count)
			return mLightmaps[index];
		return default;
	}

	/// Replaces the lightmap texture at the given index.
	public void SetLightmap(int32 index, ITextureView textureView, int32 width, int32 height)
	{
		if (index >= 0 && index < mLightmaps.Count)
		{
			mLightmaps[index] = .()
			{
				TextureView = textureView,
				Width = width,
				Height = height
			};
		}
	}

	/// Removes all lightmap textures.
	public void ClearLightmaps()
	{
		mLightmaps.Clear();
	}

	// ===== Helpers =====

	/// Calculates recommended lightmap resolution for an object given its world-space size.
	public int32 CalculateResolution(float worldSize)
	{
		let texels = (int32)(worldSize * TexelsPerUnit);
		// Round up to next power of two
		return NextPowerOfTwo(Math.Max(texels, 4));
	}

	/// Creates a lightmap render target texture.
	public static Result<ITexture> CreateLightmapTexture(IDevice device, int32 width, int32 height)
	{
		var desc = TextureDescriptor.Texture2D(
			(uint32)width, (uint32)height,
			.RGBA8Unorm,
			.RenderTarget | .Sampled | .CopySrc | .CopyDst
		);

		if (device.CreateTexture(&desc) case .Ok(let tex))
			return .Ok(tex);
		else
			return .Err;
	}

	/// Creates an HDR lightmap render target texture for high-quality baking.
	public static Result<ITexture> CreateHDRLightmapTexture(IDevice device, int32 width, int32 height)
	{
		var desc = TextureDescriptor.Texture2D(
			(uint32)width, (uint32)height,
			.RGBA16Float,
			.RenderTarget | .Sampled | .CopySrc | .CopyDst
		);

		if (device.CreateTexture(&desc) case .Ok(let tex))
			return .Ok(tex);
		else
			return .Err;
	}

	/// Gets the lightmap texture view for the given index, for binding to the GPU.
	/// Returns null if the index is invalid.
	public ITextureView GetLightmapView(int32 index)
	{
		if (index >= 0 && index < mLightmaps.Count)
			return mLightmaps[index].TextureView;
		return null;
	}

	// ===== Private =====

	private static int32 NextPowerOfTwo(int32 v)
	{
		var val = v - 1;
		val |= val >> 1;
		val |= val >> 2;
		val |= val >> 4;
		val |= val >> 8;
		val |= val >> 16;
		return val + 1;
	}
}
