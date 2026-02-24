using System;
using Sedulous.Foundation.Mathematics;

namespace Sedulous.Engine.Renderer;

/// Optimized frustum-AABB culling using precomputed positive vertex selection.
///
/// For each of the 6 frustum planes, precomputes which AABB corner
/// (the "positive vertex" — furthest in the direction of the plane normal)
/// to test. If the positive vertex is behind the plane, the entire box
/// is outside the frustum. This reduces each plane test to a single
/// dot product + comparison instead of the full 8-corner test.
///
public struct FrustumCuller
{
	/// Plane normals + distances (Ax + By + Cz + D form).
	public Vector4[6] Planes;

	/// For each plane, which components of the AABB max (vs min) to use
	/// for the positive vertex. true = use Max for that axis.
	public bool[6] PosX;
	public bool[6] PosY;
	public bool[6] PosZ;

	/// Creates a FrustumCuller from a BoundingFrustum.
	public this(BoundingFrustum frustum)
	{
		this = default;
		Plane[6] frustumPlanes = default;
		frustumPlanes[0] = frustum.Near;
		frustumPlanes[1] = frustum.Far;
		frustumPlanes[2] = frustum.Left;
		frustumPlanes[3] = frustum.Right;
		frustumPlanes[4] = frustum.Top;
		frustumPlanes[5] = frustum.Bottom;

		for (int i = 0; i < 6; i++)
		{
			let p = frustumPlanes[i];
			// Negate planes: BoundingFrustum stores outward-pointing normals,
			// but the p-vertex culling test (dot < 0 → outside) requires
			// inward-pointing normals where dot > 0 means inside the frustum.
			Planes[i] = .(-p.Normal.X, -p.Normal.Y, -p.Normal.Z, -p.D);

			// Positive vertex: for each axis, pick Max if (inward) normal component is positive
			PosX[i] = -p.Normal.X >= 0;
			PosY[i] = -p.Normal.Y >= 0;
			PosZ[i] = -p.Normal.Z >= 0;
		}
	}

	/// Creates a FrustumCuller from a view-projection matrix.
	public this(Matrix viewProjection)
	{
		this = .(BoundingFrustum(viewProjection));
	}

	/// Tests whether an AABB is inside or intersects the frustum.
	/// Returns true if the box should be drawn (not fully outside).
	[Inline]
	public bool TestAABB(BoundingBox @box)
	{
		for (int i = 0; i < 6; i++)
		{
			// Build positive vertex (the AABB corner most aligned with the plane normal)
			float px = PosX[i] ? @box.Max.X : @box.Min.X;
			float py = PosY[i] ? @box.Max.Y : @box.Min.Y;
			float pz = PosZ[i] ? @box.Max.Z : @box.Min.Z;

			// Dot product with plane
			let dot = Planes[i].X * px + Planes[i].Y * py + Planes[i].Z * pz + Planes[i].W;

			// If the positive vertex is behind the plane, box is fully outside
			if (dot < 0)
				return false;
		}
		return true;
	}

	/// Tests an AABB and returns full containment information.
	/// Returns .Disjoint, .Intersects, or .Contains.
	public ContainmentType TestAABBContainment(BoundingBox @box)
	{
		bool intersects = false;

		for (int i = 0; i < 6; i++)
		{
			// Test positive vertex (p-vertex)
			float px = PosX[i] ? @box.Max.X : @box.Min.X;
			float py = PosY[i] ? @box.Max.Y : @box.Min.Y;
			float pz = PosZ[i] ? @box.Max.Z : @box.Min.Z;
			let pDot = Planes[i].X * px + Planes[i].Y * py + Planes[i].Z * pz + Planes[i].W;

			if (pDot < 0)
				return .Disjoint;

			// Test negative vertex (n-vertex) — opposite corner
			float nx = PosX[i] ? @box.Min.X : @box.Max.X;
			float ny = PosY[i] ? @box.Min.Y : @box.Max.Y;
			float nz = PosZ[i] ? @box.Min.Z : @box.Max.Z;
			let nDot = Planes[i].X * nx + Planes[i].Y * ny + Planes[i].Z * nz + Planes[i].W;

			if (nDot < 0)
				intersects = true;
		}

		return intersects ? .Intersects : .Contains;
	}
}
