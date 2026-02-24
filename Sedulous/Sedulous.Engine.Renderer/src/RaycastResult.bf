using System;
using Sedulous.Foundation.Mathematics;

namespace Sedulous.Engine.Renderer;

/// Result of a raycast against scene drawables.
public struct RaycastResult
{
	/// The drawable that was hit.
	public Drawable Drawable;
	/// Distance along the ray to the hit point.
	public float Distance;
	/// World-space hit position.
	public Vector3 Position;
	/// Surface normal at the hit point (may be approximate).
	public Vector3 Normal;
	/// Sub-mesh/batch index that was hit.
	public int32 SubMeshIndex;
}
