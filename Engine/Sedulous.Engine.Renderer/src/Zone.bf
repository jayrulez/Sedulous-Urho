using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Renderer;

/// Zone component defining environmental rendering properties for an area.
///
/// Zones specify ambient lighting and fog for drawables within their bounds.
/// When multiple zones overlap, the one with highest priority is used.
/// A default zone with infinite bounds provides global fallback settings.
///
/// Zone extends Drawable so it can be inserted into the Octree for spatial
/// queries by the renderer.
///
[EngineComponent("Rendering")]
public class Zone : Drawable
{
	private Color mAmbientColor = .(0.2f, 0.2f, 0.2f, 1.0f);
	private Color mFogColor = .(0.5f, 0.5f, 0.7f, 1.0f);
	private float mFogStart = 250.0f;
	private float mFogEnd = 1000.0f;
	private int32 mPriority = 0;
	private EnvironmentMap mEnvironmentMap;

	public this()
	{
		SetDrawableType(.Zone);
		// Default zone has infinite bounds
		BoundingBox = .(Vector3(-1e10f), Vector3(1e10f));
	}

	// ===== Properties =====

	/// Ambient light color and intensity.
	public Color AmbientColor
	{
		get => mAmbientColor;
		set => mAmbientColor = value;
	}

	/// Fog color.
	public Color FogColor
	{
		get => mFogColor;
		set => mFogColor = value;
	}

	/// Distance at which fog begins.
	public float FogStart
	{
		get => mFogStart;
		set => mFogStart = Math.Max(value, 0.0f);
	}

	/// Distance at which fog is fully opaque.
	public float FogEnd
	{
		get => mFogEnd;
		set => mFogEnd = Math.Max(value, mFogStart);
	}

	/// Priority for overlapping zones (higher wins).
	public int32 Priority
	{
		get => mPriority;
		set => mPriority = value;
	}

	/// IBL environment map for this zone (optional).
	/// When set, drawables in this zone use IBL for ambient lighting.
	public EnvironmentMap EnvironmentMap
	{
		get => mEnvironmentMap;
		set => mEnvironmentMap = value;
	}

	/// World-space bounds of this zone.
	public BoundingBox Bounds
	{
		get => BoundingBox;
		set => BoundingBox = value;
	}

	// ===== Methods =====

	/// Returns true if the given point is inside this zone.
	public bool Contains(Vector3 point)
	{
		return WorldBoundingBox.Contains(point) != .Disjoint;
	}
}
