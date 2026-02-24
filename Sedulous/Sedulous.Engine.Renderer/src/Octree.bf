using System;
using System.Collections;
using System.Threading;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Renderer;

using internal Sedulous.Engine.Renderer;

/// An octant (node) in the octree spatial subdivision.
internal class Octant
{
	public BoundingBox WorldBounds;
	public Vector3 Center;
	public float HalfSize;
	public int Level;
	public Octant Parent;
	public Octant[8] Children;
	public List<Drawable> Drawables = new .() ~ delete _;

	public this(BoundingBox bounds, int level, Octant parent)
	{
		WorldBounds = bounds;
		Center = (bounds.Min + bounds.Max) * 0.5f;
		HalfSize = (bounds.Max.X - bounds.Min.X) * 0.5f;
		Level = level;
		Parent = parent;
	}

	public ~this()
	{
		for (int i = 0; i < 8; i++)
		{
			if (Children[i] != null)
				delete Children[i];
		}
	}

	/// Gets or creates a child octant at the given index (0-7).
	public Octant GetOrCreateChild(int index)
	{
		if (Children[index] == null)
		{
			let childHalf = HalfSize * 0.5f;
			var min = Center;
			if ((index & 1) == 0) min.X -= childHalf; else min.X = Center.X;
			if ((index & 2) == 0) min.Y -= childHalf; else min.Y = Center.Y;
			if ((index & 4) == 0) min.Z -= childHalf; else min.Z = Center.Z;

			let childBounds = BoundingBox(min, min + Vector3(childHalf));

			Children[index] = new Octant(childBounds, Level + 1, this);
		}
		return Children[index];
	}

	/// Determines which child octant a bounding box would best fit in.
	/// Returns -1 if the box doesn't fit entirely within any child.
	public int GetChildIndex(BoundingBox @box)
	{
		int index = 0;
		bool fitX, fitY, fitZ;

		if (@box.Min.X >= Center.X)
		{
			index |= 1;
			fitX = @box.Max.X <= WorldBounds.Max.X;
		}
		else if (@box.Max.X <= Center.X)
		{
			fitX = @box.Min.X >= WorldBounds.Min.X;
		}
		else
			return -1; // Straddles X boundary

		if (@box.Min.Y >= Center.Y)
		{
			index |= 2;
			fitY = @box.Max.Y <= WorldBounds.Max.Y;
		}
		else if (@box.Max.Y <= Center.Y)
		{
			fitY = @box.Min.Y >= WorldBounds.Min.Y;
		}
		else
			return -1; // Straddles Y boundary

		if (@box.Min.Z >= Center.Z)
		{
			index |= 4;
			fitZ = @box.Max.Z <= WorldBounds.Max.Z;
		}
		else if (@box.Max.Z <= Center.Z)
		{
			fitZ = @box.Min.Z >= WorldBounds.Min.Z;
		}
		else
			return -1; // Straddles Z boundary

		if (fitX && fitY && fitZ)
			return index;
		return -1;
	}
}

/// Octree spatial index for efficient visibility culling and spatial queries.
///
/// The Octree is a Component attached to the Scene root node. Drawables
/// register with the octree when they enter the scene and are placed into
/// octants based on their world bounding box. The octree supports frustum
/// culling, sphere/box queries, and raycasting.
///
[EngineComponent("Rendering")]
public class Octree : Component
{
	private const int DEFAULT_MAX_LEVELS = 8;
	private const float DEFAULT_WORLD_SIZE = 1000.0f;
	private const float MIN_OCTANT_SIZE = 1.0f;

	private Octant mRoot ~ delete _;
	private int mMaxLevels;
	private List<Drawable> mPendingUpdates = new .() ~ delete _;
	private int mDrawableCount = 0;

	// ===== Properties =====

	/// Total number of drawables in the octree.
	public int DrawableCount => mDrawableCount;

	/// The world bounds of the root octant.
	public BoundingBox WorldBounds => mRoot != null ? mRoot.WorldBounds : BoundingBox(.Zero, .Zero);

	// ===== Construction =====

	public this()
	{
		let halfSize = DEFAULT_WORLD_SIZE * 0.5f;
		let bounds = BoundingBox(Vector3(-halfSize), Vector3(halfSize));
		mRoot = new Octant(bounds, 0, null);
		mMaxLevels = DEFAULT_MAX_LEVELS;
	}

	/// Sets the world size and maximum subdivision levels.
	public void SetSize(BoundingBox worldBounds, int maxLevels)
	{
		// Rebuild the tree
		List<Drawable> allDrawables = scope .();
		if (mRoot != null)
		{
			CollectAllDrawables(mRoot, allDrawables);
			delete mRoot;
		}

		mMaxLevels = Math.Max(maxLevels, 1);
		mRoot = new Octant(worldBounds, 0, null);

		// Re-insert all drawables
		for (let drawable in allDrawables)
			InsertDrawable(drawable, mRoot);
	}

	// ===== Drawable Management =====

	/// Inserts a drawable into the octree.
	public void Insert(Drawable drawable)
	{
		if (drawable == null || mRoot == null)
			return;

		InsertDrawable(drawable, mRoot);
		drawable.OctreeRef = this;
		mDrawableCount++;
	}

	/// Removes a drawable from the octree.
	public void Remove(Drawable drawable)
	{
		if (drawable == null)
			return;

		RemoveDrawable(drawable);
		drawable.OctreeRef = null;
		drawable.ClearOctreeDirty();
		mDrawableCount--;
	}

	/// Queues a drawable for reinsertion (called when its bounds change).
	public void QueueUpdate(Drawable drawable)
	{
		if (drawable != null && !mPendingUpdates.Contains(drawable))
			mPendingUpdates.Add(drawable);
	}

	/// Processes all pending reinsertion requests.
	/// Called once per frame by the renderer before culling.
	public void Update()
	{
		for (let drawable in mPendingUpdates)
		{
			if (drawable.OctreeRef == this)
			{
				RemoveDrawable(drawable);
				InsertDrawable(drawable, mRoot);
				drawable.ClearOctreeDirty();
			}
		}
		mPendingUpdates.Clear();
	}

	// ===== Spatial Queries =====

	/// Queries drawables visible within a frustum.
	public void QueryFrustum(BoundingFrustum frustum, List<Drawable> results,
		DrawableType typeMask = .All, uint32 viewMask = 0xFFFFFFFF)
	{
		if (mRoot != null)
		{
			// Use optimized culler with precomputed positive vertex selection
			let culler = FrustumCuller(frustum);
			QueryFrustumOptimized(mRoot, culler, results, typeMask, viewMask, false);
		}
	}

	/// Queries drawables visible within a frustum using parallel traversal.
	/// Splits work across top-level octants for multi-threaded culling.
	/// Results from each thread are merged into the output list.
	public void QueryFrustumParallel(BoundingFrustum frustum, List<Drawable> results,
		DrawableType typeMask = .All, uint32 viewMask = 0xFFFFFFFF)
	{
		if (mRoot == null)
			return;

		let culler = FrustumCuller(frustum);

		// First add drawables from root octant (must always be checked)
		for (let drawable in mRoot.Drawables)
		{
			if (!drawable.Enabled) continue;
			if ((drawable.DrawableType & typeMask) == .None) continue;
			if ((drawable.ViewMask & viewMask) == 0) continue;
			if (culler.TestAABB(drawable.WorldBoundingBox))
				results.Add(drawable);
		}

		// Count active children for parallelism decision
		int activeChildren = 0;
		for (int i = 0; i < 8; i++)
			if (mRoot.Children[i] != null)
				activeChildren++;

		// If few children, fall back to serial (overhead not worth it)
		if (activeChildren <= 2)
		{
			for (int i = 0; i < 8; i++)
			{
				if (mRoot.Children[i] != null)
					QueryFrustumOptimized(mRoot.Children[i], culler, results, typeMask, viewMask, false);
			}
			return;
		}

		// Parallel: each child gets its own result list
		List<Drawable>[8] threadResults = default;
		for (int i = 0; i < 8; i++)
			if (mRoot.Children[i] != null)
				threadResults[i] = scope:: List<Drawable>();

		// Process children in parallel using ThreadPool-style approach
		// For now, use a simple parallel-for pattern
		System.Threading.WaitEvent doneEvent = scope .(true);
		int32 remaining = (int32)activeChildren;

		for (int i = 0; i < 8; i++)
		{
			if (mRoot.Children[i] == null) continue;

			let childOctant = mRoot.Children[i];
			let childResults = threadResults[i];
			let cullerCopy = culler;
			let mask = typeMask;
			let vMask = viewMask;

			ThreadPool.QueueUserWorkItem(new [&remaining, &doneEvent, =childOctant, =cullerCopy, =childResults, =mask, =vMask] () =>
			{
				QueryFrustumOptimized(childOctant, cullerCopy, childResults, mask, vMask, false);
				if (Interlocked.Decrement(ref remaining) == 0)
					doneEvent.Set();
			});
		}

		// Wait for all children to complete
		doneEvent.WaitFor();

		// Merge results
		for (int i = 0; i < 8; i++)
		{
			if (threadResults[i] != null)
			{
				for (let drawable in threadResults[i])
					results.Add(drawable);
			}
		}
	}

	/// Queries drawables within a bounding sphere.
	public void QuerySphere(BoundingSphere sphere, List<Drawable> results,
		DrawableType typeMask = .All, uint32 viewMask = 0xFFFFFFFF)
	{
		if (mRoot != null)
			QuerySphereRecursive(mRoot, sphere, results, typeMask, viewMask);
	}

	/// Queries drawables within a bounding box.
	public void QueryBox(BoundingBox @box, List<Drawable> results,
		DrawableType typeMask = .All, uint32 viewMask = 0xFFFFFFFF)
	{
		if (mRoot != null)
			QueryBoxRecursive(mRoot, @box, results, typeMask, viewMask);
	}

	/// Casts a ray and returns all hit drawables sorted by distance.
	public void Raycast(Ray ray, float maxDistance, List<RaycastResult> results,
		DrawableType typeMask = .All, uint32 viewMask = 0xFFFFFFFF)
	{
		if (mRoot != null)
		{
			RaycastRecursive(mRoot, ray, maxDistance, results, typeMask, viewMask);
			results.Sort(scope (a, b) => {
				if (a.Distance < b.Distance) return -1;
				if (a.Distance > b.Distance) return 1;
				return 0;
			});
		}
	}

	/// Casts a ray and returns the closest hit.
	public bool RaycastSingle(Ray ray, float maxDistance, out RaycastResult result,
		DrawableType typeMask = .All, uint32 viewMask = 0xFFFFFFFF)
	{
		List<RaycastResult> results = scope .();
		Raycast(ray, maxDistance, results, typeMask, viewMask);
		if (results.Count > 0)
		{
			result = results[0];
			return true;
		}
		result = default;
		return false;
	}

	// ===== Private: Insertion =====

	private void InsertDrawable(Drawable drawable, Octant octant)
	{
		let @box = drawable.WorldBoundingBox;

		// If we've reached max depth or the box is too big, put it here
		if (octant.Level >= mMaxLevels || octant.HalfSize <= MIN_OCTANT_SIZE)
		{
			octant.Drawables.Add(drawable);
			return;
		}

		let childIndex = octant.GetChildIndex(@box);
		if (childIndex >= 0)
		{
			let child = octant.GetOrCreateChild(childIndex);
			InsertDrawable(drawable, child);
		}
		else
		{
			// Doesn't fit in any child — store at this level
			octant.Drawables.Add(drawable);
		}
	}

	private void RemoveDrawable(Drawable drawable)
	{
		if (mRoot != null)
			RemoveDrawableRecursive(drawable, mRoot);
	}

	private bool RemoveDrawableRecursive(Drawable drawable, Octant octant)
	{
		if (octant.Drawables.Remove(drawable))
			return true;

		for (int i = 0; i < 8; i++)
		{
			if (octant.Children[i] != null)
			{
				if (RemoveDrawableRecursive(drawable, octant.Children[i]))
					return true;
			}
		}
		return false;
	}

	// ===== Private: Queries =====

	/// Optimized frustum query using FrustumCuller with precomputed positive vertex.
	/// When parentContained is true, skips octant bounds test (parent was fully inside).
	private static void QueryFrustumOptimized(Octant octant, FrustumCuller culler,
		List<Drawable> results, DrawableType typeMask, uint32 viewMask, bool parentContained)
	{
		bool fullyContained = parentContained;

		if (!parentContained)
		{
			let containment = culler.TestAABBContainment(octant.WorldBounds);
			if (containment == .Disjoint)
				return;
			fullyContained = (containment == .Contains);
		}

		// Test drawables in this octant
		for (let drawable in octant.Drawables)
		{
			if (!drawable.Enabled)
				continue;
			if ((drawable.DrawableType & typeMask) == .None)
				continue;
			if ((drawable.ViewMask & viewMask) == 0)
				continue;

			if (fullyContained || culler.TestAABB(drawable.WorldBoundingBox))
				results.Add(drawable);
		}

		// Recurse into children
		for (int i = 0; i < 8; i++)
		{
			if (octant.Children[i] != null)
				QueryFrustumOptimized(octant.Children[i], culler, results, typeMask, viewMask, fullyContained);
		}
	}

	private void QuerySphereRecursive(Octant octant, BoundingSphere sphere,
		List<Drawable> results, DrawableType typeMask, uint32 viewMask)
	{
		if (!sphere.Intersects(octant.WorldBounds))
			return;

		for (let drawable in octant.Drawables)
		{
			if (!drawable.Enabled)
				continue;
			if ((drawable.DrawableType & typeMask) == .None)
				continue;
			if ((drawable.ViewMask & viewMask) == 0)
				continue;

			if (sphere.Intersects(drawable.WorldBoundingBox))
				results.Add(drawable);
		}

		for (int i = 0; i < 8; i++)
		{
			if (octant.Children[i] != null)
				QuerySphereRecursive(octant.Children[i], sphere, results, typeMask, viewMask);
		}
	}

	private void QueryBoxRecursive(Octant octant, BoundingBox @box,
		List<Drawable> results, DrawableType typeMask, uint32 viewMask)
	{
		if (!@box.Intersects(octant.WorldBounds))
			return;

		for (let drawable in octant.Drawables)
		{
			if (!drawable.Enabled)
				continue;
			if ((drawable.DrawableType & typeMask) == .None)
				continue;
			if ((drawable.ViewMask & viewMask) == 0)
				continue;

			if (@box.Intersects(drawable.WorldBoundingBox))
				results.Add(drawable);
		}

		for (int i = 0; i < 8; i++)
		{
			if (octant.Children[i] != null)
				QueryBoxRecursive(octant.Children[i], @box, results, typeMask, viewMask);
		}
	}

	private void RaycastRecursive(Octant octant, Ray ray, float maxDistance,
		List<RaycastResult> results, DrawableType typeMask, uint32 viewMask)
	{
		if (let dist = octant.WorldBounds.Intersects(ray))
		{
			if (dist > maxDistance)
				return;
		}
		else
			return;

		for (let drawable in octant.Drawables)
		{
			if (!drawable.Enabled)
				continue;
			if ((drawable.DrawableType & typeMask) == .None)
				continue;
			if ((drawable.ViewMask & viewMask) == 0)
				continue;

			drawable.ProcessRayQuery(ray, results);
		}

		for (int i = 0; i < 8; i++)
		{
			if (octant.Children[i] != null)
				RaycastRecursive(octant.Children[i], ray, maxDistance, results, typeMask, viewMask);
		}
	}

	// ===== Private: Helpers =====

	private void CollectAllDrawables(Octant octant, List<Drawable> results)
	{
		for (let drawable in octant.Drawables)
			results.Add(drawable);

		for (int i = 0; i < 8; i++)
		{
			if (octant.Children[i] != null)
				CollectAllDrawables(octant.Children[i], results);
		}
	}
}
