using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Renderer;

/// Type of light source.
public enum LightType
{
	/// Parallel rays from an infinitely distant source (sun).
	Directional,
	/// Omnidirectional light emanating from a point.
	Point,
	/// Cone-shaped light from a point.
	Spot
}

/// Light component that illuminates the scene.
///
/// Lights are Drawables so they can be inserted into the Octree for
/// spatial queries. The renderer queries the octree for lights that
/// affect visible geometry.
///
[EngineComponent("Rendering")]
public class Light : Drawable
{
	private LightType mLightType = .Directional;
	private Color mColor = .(1.0f, 1.0f, 1.0f, 1.0f);
	private float mBrightness = 1.0f;
	private float mRange = 10.0f;
	private float mSpotFov = Math.PI_f / 4.0f; // 45 degrees
	private float mSpotInnerFov = 0.0f;
	private float mSpecularIntensity = 1.0f;

	// Shadow settings
	private bool mCastShadowsLight = false;
	private float mShadowBias = 0.0002f;
	private float mShadowSlopeScaledBias = 1.0f;
	private float mShadowNormalOffset = 3.0f;
	private float mShadowResolution = 1.0f;
	private int32 mShadowCascadeCount = 3;
	private float mShadowSplitLambda = 0.5f;
	private float[4] mShadowCascadeSplits = .(0.15f, 1.0f, 0.5f, 1.0f);

	public this()
	{
		SetDrawableType(.Light);
		// Directional lights have infinite bounds
		BoundingBox = .(Vector3(-1e10f), Vector3(1e10f));
		// Default shadow distance for lights (overrides Drawable's 0 default)
		ShadowDistance = 150.0f;
	}

	// ===== Properties =====

	/// The type of light source.
	public LightType LightType
	{
		get => mLightType;
		set
		{
			mLightType = value;
			UpdateBounds();
		}
	}

	/// Light color.
	public Color LightColor
	{
		get => mColor;
		set => mColor = value;
	}

	/// Brightness multiplier.
	public float Brightness
	{
		get => mBrightness;
		set => mBrightness = Math.Max(value, 0.0f);
	}

	/// Effective color (color * brightness).
	public Color EffectiveColor => Color(mColor.R * mBrightness, mColor.G * mBrightness,
		mColor.B * mBrightness, mColor.A);

	/// Range for point and spot lights.
	public float Range
	{
		get => mRange;
		set
		{
			mRange = Math.Max(value, 0.01f);
			UpdateBounds();
		}
	}

	/// Outer cone angle in radians (spot light).
	public float SpotFov
	{
		get => mSpotFov;
		set
		{
			mSpotFov = Math.Clamp(value, 0.01f, Math.PI_f - 0.01f);
			UpdateBounds();
		}
	}

	/// Inner cone angle in radians (spot light, full intensity).
	public float SpotInnerFov
	{
		get => mSpotInnerFov;
		set => mSpotInnerFov = Math.Clamp(value, 0.0f, mSpotFov);
	}

	/// Specular intensity multiplier.
	public float SpecularIntensity
	{
		get => mSpecularIntensity;
		set => mSpecularIntensity = Math.Max(value, 0.0f);
	}

	// ===== Shadow Properties =====

	/// Whether this light casts shadows.
	public bool CastShadowsLight
	{
		get => mCastShadowsLight;
		set => mCastShadowsLight = value;
	}

	/// Depth bias for shadow mapping.
	public float ShadowBias
	{
		get => mShadowBias;
		set => mShadowBias = value;
	}

	/// Slope-scaled depth bias.
	public float ShadowSlopeScaledBias
	{
		get => mShadowSlopeScaledBias;
		set => mShadowSlopeScaledBias = value;
	}

	/// Normal offset bias.
	public float ShadowNormalOffset
	{
		get => mShadowNormalOffset;
		set => mShadowNormalOffset = value;
	}

	/// Shadow map resolution multiplier.
	public float ShadowResolution
	{
		get => mShadowResolution;
		set => mShadowResolution = Math.Max(value, 0.1f);
	}

	/// Number of shadow cascades (directional light only, 1-4).
	public int32 ShadowCascadeCount
	{
		get => mShadowCascadeCount;
		set => mShadowCascadeCount = Math.Clamp(value, 1, 4);
	}

	/// Lambda for practical cascade split scheme (0=uniform, 1=logarithmic, 0.5=balanced).
	public float ShadowSplitLambda
	{
		get => mShadowSplitLambda;
		set => mShadowSplitLambda = Math.Clamp(value, 0.0f, 1.0f);
	}

	// ===== Methods =====

	/// Gets the light's world direction (forward vector of the node).
	public Vector3 Direction
	{
		get
		{
			if (Node != null)
				return Node.WorldDirection;
			return .Forward;
		}
	}

	/// Gets the light's world position.
	public Vector3 WorldPosition
	{
		get
		{
			if (Node != null)
				return Node.WorldPosition;
			return .Zero;
		}
	}

	/// Gets the shadow cascade split distance at the given index (0-3).
	public float GetShadowCascadeSplit(int index)
	{
		if (index >= 0 && index < 4)
			return mShadowCascadeSplits[index];
		return 1.0f;
	}

	/// Sets the shadow cascade split distance at the given index (0-3).
	/// Split values are proportions of the camera's far clip distance (0..1).
	public void SetShadowCascadeSplit(int index, float value)
	{
		if (index >= 0 && index < 4)
			mShadowCascadeSplits[index] = Math.Clamp(value, 0.0f, 1.0f);
	}

	// ===== Private =====

	private void UpdateBounds()
	{
		switch (mLightType)
		{
		case .Directional:
			BoundingBox = .(Vector3(-1e10f), Vector3(1e10f));
		case .Point:
			BoundingBox = .(Vector3(-mRange), Vector3(mRange));
		case .Spot:
			// Approximate bounding box for a cone
			let halfAngle = mSpotFov * 0.5f;
			let endRadius = mRange * Math.Tan(halfAngle);
			let maxExtent = Math.Max(mRange, endRadius);
			BoundingBox = .(Vector3(-maxExtent), Vector3(maxExtent));
		}
	}

	protected override void OnTransformChanged()
	{
		base.OnTransformChanged();
	}
}
