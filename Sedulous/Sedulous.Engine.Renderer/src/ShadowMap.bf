using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// Per-cascade shadow data for a single shadow-casting light.
public struct ShadowCascade
{
	/// View matrix from the light's perspective for this cascade.
	public Matrix ViewMatrix;
	/// Projection matrix for this cascade.
	public Matrix ProjectionMatrix;
	/// Combined view-projection matrix.
	public Matrix ViewProjectionMatrix;
	/// Split distance (near) in view space.
	public float SplitNear;
	/// Split distance (far) in view space.
	public float SplitFar;
	/// UV offset+scale into the shadow atlas for this cascade.
	public Vector4 AtlasRect;
}

/// Manages shadow map textures and cascade computation for shadow-casting lights.
///
/// Each shadow-casting light gets one or more shadow cascades. Directional
/// lights use cascaded shadow maps (CSM); spot lights use a single shadow map.
/// All shadow maps are packed into a single atlas texture.
///
public class ShadowMap
{
	private IDevice mDevice;
	private ITexture mAtlasTexture ~ { if (_ != null) delete _; };
	private ITextureView mAtlasView ~ { if (_ != null) delete _; };
	private ITextureView mAtlasDepthView ~ { if (_ != null) delete _; };
	private uint32 mAtlasSize;
	private List<ShadowCascade> mCascades = new .() ~ delete _;

	public this(IDevice device, uint32 atlasSize = 2048)
	{
		mDevice = device;
		mAtlasSize = atlasSize;
	}

	// ===== Properties =====

	/// The shadow atlas texture.
	public ITexture AtlasTexture => mAtlasTexture;

	/// The shadow atlas depth view (for sampling in shaders).
	public ITextureView AtlasDepthView => mAtlasDepthView;

	/// The shadow atlas view (for render target attachment).
	public ITextureView AtlasView => mAtlasView;

	/// Atlas size in pixels (square).
	public uint32 AtlasSize => mAtlasSize;

	/// Current cascade data.
	public List<ShadowCascade> Cascades => mCascades;

	// ===== Atlas Management =====

	/// Creates the shadow atlas depth texture.
	public Result<void> CreateAtlas()
	{
		// Clean up old atlas
		if (mAtlasDepthView != null) { delete mAtlasDepthView; mAtlasDepthView = null; }
		if (mAtlasView != null) { delete mAtlasView; mAtlasView = null; }
		if (mAtlasTexture != null) { delete mAtlasTexture; mAtlasTexture = null; }

		var desc = TextureDescriptor.Texture2D(mAtlasSize, mAtlasSize, .Depth32Float, .DepthStencil | .Sampled);
		desc.Label = "ShadowAtlas";

		if (mDevice.CreateTexture(&desc) case .Ok(let tex))
		{
			mAtlasTexture = tex;

			TextureViewDescriptor viewDesc = .()
			{
				Format = .Depth32Float,
				Dimension = .Texture2D,
				BaseMipLevel = 0,
				MipLevelCount = 1,
				BaseArrayLayer = 0,
				ArrayLayerCount = 1,
				Aspect = .DepthOnly
			};

			if (mDevice.CreateTextureView(tex, &viewDesc) case .Ok(let view))
			{
				mAtlasView = view;
				mAtlasDepthView = view; // Same view for now
				return .Ok;
			}
		}

		return .Err;
	}

	// ===== Cascade Computation =====

	/// Computes shadow cascades for a directional light.
	/// camera: the scene camera for frustum splits.
	/// light: the directional light.
	public void ComputeDirectionalCascades(Camera camera, Light light)
	{
		mCascades.Clear();

		if (camera == null || light == null)
			return;

		let cascadeCount = light.ShadowCascadeCount;
		let lightDir = light.Direction;
		let nearClip = camera.NearClip;
		let farClip = camera.FarClip;

		for (int32 i = 0; i < cascadeCount; i++)
		{
			float splitNear = (i == 0) ? nearClip : nearClip + (farClip - nearClip) * light.GetShadowCascadeSplit(i - 1);
			float splitFar = nearClip + (farClip - nearClip) * light.GetShadowCascadeSplit(i);

			// Compute frustum corners for this split
			let splitFrustumCorners = ComputeSplitFrustumCorners(camera, splitNear, splitFar);

			// Compute light view matrix (looking along light direction)
			let center = ComputeFrustumCenter(splitFrustumCorners);
			let lightView = Matrix.CreateLookAt(center - lightDir * 100.0f, center, Vector3.Up);

			// Find bounds of split frustum in light view space
			float minX = float.MaxValue, maxX = float.MinValue;
			float minY = float.MaxValue, maxY = float.MinValue;
			float minZ = float.MaxValue, maxZ = float.MinValue;

			for (let corner in splitFrustumCorners)
			{
				let lightSpaceCorner = Vector3.Transform(corner, lightView);
				minX = Math.Min(minX, lightSpaceCorner.X);
				maxX = Math.Max(maxX, lightSpaceCorner.X);
				minY = Math.Min(minY, lightSpaceCorner.Y);
				maxY = Math.Max(maxY, lightSpaceCorner.Y);
				minZ = Math.Min(minZ, lightSpaceCorner.Z);
				maxZ = Math.Max(maxZ, lightSpaceCorner.Z);
			}

			// Extend Z range to capture shadow casters behind the frustum
			float zRange = maxZ - minZ;
			minZ -= zRange * 2.0f;

			let lightProjection = Matrix.CreateOrthographicOffCenter(minX, maxX, minY, maxY, minZ, maxZ);

			// Atlas rect: divide atlas into a grid
			float cascadeSize = 1.0f / (float)cascadeCount;
			Vector4 atlasRect = .(cascadeSize * (float)i, 0, cascadeSize, 1);

			ShadowCascade cascade = .()
			{
				ViewMatrix = lightView,
				ProjectionMatrix = lightProjection,
				ViewProjectionMatrix = lightView * lightProjection,
				SplitNear = splitNear,
				SplitFar = splitFar,
				AtlasRect = atlasRect
			};
			mCascades.Add(cascade);
		}
	}

	/// Computes a single shadow map for a spot light.
	public void ComputeSpotShadow(Light light)
	{
		mCascades.Clear();

		if (light == null)
			return;

		let lightPos = light.WorldPosition;
		let lightDir = light.Direction;
		let lightView = Matrix.CreateLookAt(lightPos, lightPos + lightDir, Vector3.Up);
		let lightProjection = Matrix.CreatePerspectiveFieldOfView(
			light.SpotFov, 1.0f, 0.1f, light.Range);

		ShadowCascade cascade = .()
		{
			ViewMatrix = lightView,
			ProjectionMatrix = lightProjection,
			ViewProjectionMatrix = lightView * lightProjection,
			SplitNear = 0.1f,
			SplitFar = light.Range,
			AtlasRect = .(0, 0, 1, 1)
		};
		mCascades.Add(cascade);
	}

	// ===== Private =====

	/// Computes 8 frustum corners for a sub-frustum between splitNear and splitFar.
	private static Vector3[8] ComputeSplitFrustumCorners(Camera camera, float splitNear, float splitFar)
	{
		// Build a custom projection for the split range
		let aspect = camera.AspectRatio;
		let fov = camera.Fov;
		let nearHalfH = Math.Tan(fov * 0.5f) * splitNear;
		let nearHalfW = nearHalfH * aspect;
		let farHalfH = Math.Tan(fov * 0.5f) * splitFar;
		let farHalfW = farHalfH * aspect;

		// Frustum corners in view space
		Vector3[8] viewCorners = .(
			// Near plane
			.(-nearHalfW, -nearHalfH, splitNear),
			.( nearHalfW, -nearHalfH, splitNear),
			.( nearHalfW,  nearHalfH, splitNear),
			.(-nearHalfW,  nearHalfH, splitNear),
			// Far plane
			.(-farHalfW, -farHalfH, splitFar),
			.( farHalfW, -farHalfH, splitFar),
			.( farHalfW,  farHalfH, splitFar),
			.(-farHalfW,  farHalfH, splitFar)
		);

		// Transform to world space using inverse view matrix
		let invView = Matrix.Invert(camera.ViewMatrix);

		Vector3[8] worldCorners = .();
		for (int i = 0; i < 8; i++)
			worldCorners[i] = Vector3.Transform(viewCorners[i], invView);

		return worldCorners;
	}

	/// Computes the center of 8 frustum corners.
	private static Vector3 ComputeFrustumCenter(Vector3[8] corners)
	{
		Vector3 center = .Zero;
		for (let c in corners)
			center = center + c;
		return center * (1.0f / 8.0f);
	}
}
