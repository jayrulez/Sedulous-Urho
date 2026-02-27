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
	/// World-space texel size for normal offset bias.
	public float WorldTexelSize;
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
	private ITextureView mAtlasDepthView; // Alias for mAtlasView — not separately owned
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
		// Clean up old atlas (mAtlasDepthView is an alias, not separately owned)
		mAtlasDepthView = null;
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
	/// Uses bounding-sphere fitting, practical split scheme, and texel snapping for stable shadows.
	public void ComputeDirectionalCascades(Camera camera, Light light)
	{
		mCascades.Clear();

		if (camera == null || light == null)
			return;

		let cascadeCount = light.ShadowCascadeCount;
		let lightDir = Vector3.Normalize(light.Direction);
		let nearClip = camera.NearClip;
		// Cap effective far distance to shadow distance for better resolution
		let effectiveFar = Math.Min(camera.FarClip, light.ShadowDistance);
		let cascadeResolution = mAtlasSize / (uint32)cascadeCount;
		let lambda = light.ShadowSplitLambda;

		for (int32 i = 0; i < cascadeCount; i++)
		{
			// Practical split scheme: blend between uniform and logarithmic distribution
			float p = (float)(i + 1) / (float)cascadeCount;
			float pPrev = (float)i / (float)cascadeCount;

			float logSplit = nearClip * Math.Pow(effectiveFar / nearClip, p);
			float uniformSplit = nearClip + (effectiveFar - nearClip) * p;
			float splitFar = lambda * logSplit + (1.0f - lambda) * uniformSplit;

			float logNear = nearClip * Math.Pow(effectiveFar / nearClip, pPrev);
			float uniformNear = nearClip + (effectiveFar - nearClip) * pPrev;
			float splitNear = (i == 0) ? nearClip : lambda * logNear + (1.0f - lambda) * uniformNear;

			// Compute frustum corners for this split
			let splitFrustumCorners = ComputeSplitFrustumCorners(camera, splitNear, splitFar);

			// Compute bounding sphere for stable shadow edges
			let center = ComputeFrustumCenter(splitFrustumCorners);
			float radius = 0;
			for (let corner in splitFrustumCorners)
			{
				let dist = Vector3.Distance(corner, center);
				radius = Math.Max(radius, dist);
			}
			// Round up to reduce shadow edge swimming
			radius = Math.Ceiling(radius * 16.0f) / 16.0f;

			// Stable up vector — avoid degenerate CreateLookAt when light is near-vertical
			Vector3 refVec = Math.Abs(lightDir.Y) < 0.9f ? Vector3.UnitY : Vector3.UnitX;
			Vector3 lightRight = Vector3.Normalize(Vector3.Cross(refVec, lightDir));
			Vector3 lightUp = Vector3.Cross(lightDir, lightRight);

			// Position light far enough back to capture shadow casters
			let shadowBackDist = radius * 2.0f;
			let lightPos = center - lightDir * shadowBackDist;
			let lightView = Matrix.CreateLookAt(lightPos, center, lightUp);

			// Symmetric orthographic projection using bounding sphere
			var lightProjection = Matrix.CreateOrthographic(radius * 2.0f, radius * 2.0f, 0.01f, shadowBackDist * 2.0f);

			// Snap to texel grid to prevent shadow edge swimming when camera moves
			var viewProj = lightView * lightProjection;
			viewProj = SnapToTexelGrid(viewProj, cascadeResolution);

			// World-space texel size = ortho width / cascade resolution (for normal offset bias)
			float worldTexelSize = (radius * 2.0f) / (float)cascadeResolution;

			// Atlas rect: divide atlas horizontally
			float cascadeSize = 1.0f / (float)cascadeCount;
			Vector4 atlasRect = .(cascadeSize * (float)i, 0, cascadeSize, 1);

			ShadowCascade cascade = .()
			{
				ViewMatrix = lightView,
				ProjectionMatrix = lightProjection,
				ViewProjectionMatrix = viewProj,
				SplitNear = splitNear,
				SplitFar = splitFar,
				AtlasRect = atlasRect,
				WorldTexelSize = worldTexelSize
			};
			mCascades.Add(cascade);
		}
	}

	/// Snaps the view-projection matrix to texel boundaries to prevent shadow swimming.
	private static Matrix SnapToTexelGrid(Matrix viewProj, uint32 resolution)
	{
		// Transform origin to shadow map space
		var shadowOrigin = Vector4.Transform(Vector4(0, 0, 0, 1), viewProj);
		shadowOrigin = shadowOrigin * ((float)resolution / 2.0f);

		// Round to nearest texel
		let roundedX = Math.Round(shadowOrigin.X);
		let roundedY = Math.Round(shadowOrigin.Y);

		// Calculate offset and apply
		var offsetX = (roundedX - shadowOrigin.X) * (2.0f / (float)resolution);
		var offsetY = (roundedY - shadowOrigin.Y) * (2.0f / (float)resolution);

		var result = viewProj;
		result.M41 += offsetX;
		result.M42 += offsetY;
		return result;
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
		// Right-handed view space: -Z is forward, so near/far are at negative Z
		Vector3[8] viewCorners = .(
			// Near plane
			.(-nearHalfW, -nearHalfH, -splitNear),
			.( nearHalfW, -nearHalfH, -splitNear),
			.( nearHalfW,  nearHalfH, -splitNear),
			.(-nearHalfW,  nearHalfH, -splitNear),
			// Far plane
			.(-farHalfW, -farHalfH, -splitFar),
			.( farHalfW, -farHalfH, -splitFar),
			.( farHalfW,  farHalfH, -splitFar),
			.(-farHalfW,  farHalfH, -splitFar)
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
