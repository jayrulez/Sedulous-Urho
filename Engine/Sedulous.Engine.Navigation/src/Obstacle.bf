using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using recastnavigation_Beef;

namespace Sedulous.Engine.Navigation;

/// The shape type of a dynamic navigation obstacle.
public enum ObstacleShape
{
	/// Cylinder defined by radius and height.
	Cylinder,
	/// Axis-aligned box defined by half-extents.
	Box,
	/// Oriented box defined by half-extents and Y-axis rotation.
	OrientedBox
}

/// Dynamic obstacle component that modifies the navigation mesh at runtime.
///
/// Requires a NavigationMesh configured with TileCache support. When added
/// to a scene, the obstacle carves out a region of the nav mesh so agents
/// path around it. Moving the owning node updates the obstacle position.
///
[EngineComponent("Navigation")]
public class Obstacle : Component
{
	private ObstacleShape mShape = .Cylinder;
	private float mRadius = 1.0f;
	private float mHeight = 2.0f;
	private Vector3 mHalfExtents = .(1.0f, 1.0f, 1.0f);
	private float mYRotation = 0;

	private dtTileCacheHandle mTileCache;
	private dtObstacleRef mObstacleRef = 0;
	private bool mIsAdded = false;

	public ~this()
	{
		RemoveFromTileCache();
	}

	// ===== Properties =====

	/// Obstacle shape type.
	[Editable("Shape")]
	public ObstacleShape Shape
	{
		get => mShape;
		set
		{
			if (mShape == value) return;
			let wasAdded = mIsAdded;
			RemoveFromTileCache();
			mShape = value;
			if (wasAdded && mTileCache != null)
				AddToTileCache(mTileCache);
		}
	}

	/// Radius for cylinder obstacles.
	[Editable("Radius")]
	public float Radius
	{
		get => mRadius;
		set => mRadius = Math.Max(value, 0.01f);
	}

	/// Height for cylinder obstacles.
	[Editable("Height")]
	public float Height
	{
		get => mHeight;
		set => mHeight = Math.Max(value, 0.01f);
	}

	/// Half-extents for box/oriented box obstacles.
	public Vector3 HalfExtents
	{
		get => mHalfExtents;
		set => mHalfExtents = value;
	}

	/// Y-axis rotation in radians for oriented box obstacles.
	[Editable("Y Rotation")]
	public float YRotation
	{
		get => mYRotation;
		set => mYRotation = value;
	}

	/// Whether this obstacle is currently active in the tile cache.
	public bool IsActive => mIsAdded;

	/// The Detour obstacle reference.
	public dtObstacleRef ObstacleRef => mObstacleRef;

	// ===== TileCache Integration =====

	/// Adds this obstacle to the given tile cache.
	public Result<void> AddToTileCache(dtTileCacheHandle tileCache)
	{
		if (tileCache == null)
			return .Err;

		RemoveFromTileCache();
		mTileCache = tileCache;

		let pos = Node?.WorldPosition ?? .Zero;
		float[3] posArr = .(pos.X, pos.Y, pos.Z);

		dtStatus status;
		switch (mShape)
		{
		case .Cylinder:
			status = dtTileCacheAddObstacle(tileCache, &posArr, mRadius, mHeight, &mObstacleRef);
		case .Box:
			float[3] bmin = .(pos.X - mHalfExtents.X, pos.Y, pos.Z - mHalfExtents.Z);
			float[3] bmax = .(pos.X + mHalfExtents.X, pos.Y + mHalfExtents.Y * 2, pos.Z + mHalfExtents.Z);
			status = dtTileCacheAddBoxObstacle(tileCache, &bmin, &bmax, &mObstacleRef);
		case .OrientedBox:
			float[3] center = .(pos.X, pos.Y, pos.Z);
			float[3] halfExt = .(mHalfExtents.X, mHalfExtents.Y, mHalfExtents.Z);
			status = dtTileCacheAddBoxObstacleOriented(tileCache, &center, &halfExt, mYRotation, &mObstacleRef);
		}

		if (dtStatusFailed(status) != 0)
		{
			mObstacleRef = 0;
			return .Err;
		}

		mIsAdded = true;
		return .Ok;
	}

	/// Removes this obstacle from the tile cache.
	public void RemoveFromTileCache()
	{
		if (mIsAdded && mTileCache != null && mObstacleRef != 0)
		{
			dtTileCacheRemoveObstacle(mTileCache, mObstacleRef);
		}
		mObstacleRef = 0;
		mIsAdded = false;
	}

	// ===== Lifecycle =====

	protected override void OnRemoved()
	{
		RemoveFromTileCache();
	}

	protected override void OnTransformChanged()
	{
		// Re-add at new position if currently active
		if (mIsAdded && mTileCache != null)
		{
			let tc = mTileCache;
			RemoveFromTileCache();
			AddToTileCache(tc);
		}
	}
}
