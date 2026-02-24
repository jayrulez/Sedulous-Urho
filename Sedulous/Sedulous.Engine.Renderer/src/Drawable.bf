using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Renderer;

/// Drawable types for octree filtering.
public enum DrawableType : uint8
{
	None = 0,
	/// Regular geometry (StaticModel, AnimatedModel, etc.)
	Geometry = 1,
	/// Light sources.
	Light = 2,
	/// Environment zones.
	Zone = 4,
	/// All types.
	All = Geometry | Light | Zone
}

/// Base class for all renderable scene objects.
///
/// Drawable extends Component and adds rendering-specific data: bounding volumes,
/// visibility masks, shadow settings, and batch generation. Drawables register
/// with the scene's Octree for spatial queries (frustum culling, raycasting, etc.)
///
/// Subclasses (StaticModel, Light, etc.) override UpdateBatches() to produce
/// SourceBatch entries for the renderer.
///
public class Drawable : Component
{
	// Bounding volumes
	private BoundingBox mBoundingBox = .(Vector3(-0.5f), Vector3(0.5f));
	private BoundingBox mWorldBoundingBox;
	private bool mWorldBoundingBoxDirty = true;

	// Rendering properties
	private float mDrawDistance = 0.0f;
	private float mShadowDistance = 0.0f;
	private float mLodBias = 1.0f;
	private float mSortValue = 0.0f;
	private bool mCastShadows = false;

	// Masks for layer-based filtering
	private uint32 mViewMask = 0xFFFFFFFF;
	private uint32 mLightMask = 0xFFFFFFFF;
	private uint32 mShadowMask = 0xFFFFFFFF;
	private uint32 mZoneMask = 0xFFFFFFFF;

	// Type identification
	private DrawableType mDrawableType = .Geometry;

	// Octree reference (not owned)
	private Octree mOctree;
	private bool mOctreeDirty = true;

	// Cached batches
	private List<SourceBatch> mBatches = new .() ~ delete _;

	// Per-frame tracking
	private uint64 mLastFrameNumber = 0;
	private float mDistance = 0.0f;

	// Lightmap assignment
	private LightmapInfo mLightmapInfo = .();

	// Zone reference (not owned, set by renderer during culling)
	private Zone mZone;

	// ===== Properties =====

	/// Local-space bounding box.
	public BoundingBox BoundingBox
	{
		get => mBoundingBox;
		set
		{
			mBoundingBox = value;
			mWorldBoundingBoxDirty = true;
			mOctreeDirty = true;
		}
	}

	/// World-space bounding box (lazily computed).
	public BoundingBox WorldBoundingBox
	{
		get
		{
			if (mWorldBoundingBoxDirty)
				UpdateWorldBoundingBox();
			return mWorldBoundingBox;
		}
	}

	/// Maximum draw distance (0 = unlimited).
	public float DrawDistance
	{
		get => mDrawDistance;
		set => mDrawDistance = Math.Max(value, 0.0f);
	}

	/// Maximum shadow casting distance (0 = use DrawDistance).
	public float ShadowDistance
	{
		get => mShadowDistance;
		set => mShadowDistance = Math.Max(value, 0.0f);
	}

	/// LOD bias multiplier. Higher = use higher LOD at same distance.
	public float LodBias
	{
		get => mLodBias;
		set => mLodBias = Math.Max(value, 0.01f);
	}

	/// Whether this drawable casts shadows.
	public bool CastShadows
	{
		get => mCastShadows;
		set => mCastShadows = value;
	}

	/// Bitmask for viewport visibility filtering.
	public uint32 ViewMask
	{
		get => mViewMask;
		set => mViewMask = value;
	}

	/// Bitmask for light interaction filtering.
	public uint32 LightMask
	{
		get => mLightMask;
		set => mLightMask = value;
	}

	/// Bitmask for shadow casting filtering.
	public uint32 ShadowMask
	{
		get => mShadowMask;
		set => mShadowMask = value;
	}

	/// Bitmask for zone assignment.
	public uint32 ZoneMask
	{
		get => mZoneMask;
		set => mZoneMask = value;
	}

	/// The type of this drawable (Geometry, Light, Zone).
	public DrawableType DrawableType => mDrawableType;

	/// Distance from camera (set during culling).
	public float Distance => mDistance;

	/// Current zone this drawable belongs to.
	public Zone CurrentZone => mZone;

	/// The source batches for the current frame.
	public Span<SourceBatch> Batches => mBatches;

	/// Lightmap assignment for this drawable (index into atlas + UV scale/offset).
	public LightmapInfo LightmapInfo
	{
		get => mLightmapInfo;
		set => mLightmapInfo = value;
	}

	/// Whether this drawable has a valid lightmap assignment.
	public bool IsLightmapped => mLightmapInfo.LightmapIndex >= 0;

	// ===== Virtual Methods =====

	/// Updates source batches for the current frame.
	/// Called by the renderer after culling. Subclasses override this
	/// to generate their draw call data.
	public virtual void UpdateBatches(FrameInfo frameInfo)
	{
	}

	/// Processes a raycast query against this drawable.
	/// Subclasses can override for more accurate (e.g. triangle-level) tests.
	/// Default implementation tests against the world bounding box.
	public virtual void ProcessRayQuery(Ray ray, List<RaycastResult> results)
	{
		if (let distance = WorldBoundingBox.Intersects(ray))
		{
			RaycastResult result = .()
			{
				Drawable = this,
				Distance = distance,
				Position = ray.Position + ray.Direction * distance,
				Normal = .Zero,
				SubMeshIndex = -1
			};
			results.Add(result);
		}
	}

	// ===== Internal =====

	/// Sets the drawable type. Called by subclass constructors.
	protected void SetDrawableType(DrawableType type)
	{
		mDrawableType = type;
	}

	/// Sets the distance from camera. Called by the renderer during culling.
	internal void SetDistance(float distance)
	{
		mDistance = distance;
	}

	/// Sets the zone for this drawable. Called by the renderer.
	internal void SetZone(Zone zone)
	{
		mZone = zone;
	}

	/// Sets the sort value for rendering order.
	internal void SetSortValue(float value)
	{
		mSortValue = value;
	}

	/// Gets the sort value.
	internal float SortValue => mSortValue;

	/// Whether this drawable needs octree reinsertion.
	internal bool OctreeDirty => mOctreeDirty;

	/// Clears the octree dirty flag.
	internal void ClearOctreeDirty()
	{
		mOctreeDirty = false;
	}

	/// Gets/sets the octree this drawable is inserted into.
	internal Octree OctreeRef
	{
		get => mOctree;
		set => mOctree = value;
	}

	/// Marks the last frame this drawable was processed.
	internal void MarkFrame(uint64 frameNumber)
	{
		mLastFrameNumber = frameNumber;
	}

	/// Whether this drawable was already processed this frame.
	internal bool WasProcessedThisFrame(uint64 frameNumber)
	{
		return mLastFrameNumber == frameNumber;
	}

	/// Access to the mutable batches list for subclasses.
	protected List<SourceBatch> MutableBatches => mBatches;

	// ===== Lifecycle =====

	protected override void OnTransformChanged()
	{
		mWorldBoundingBoxDirty = true;
		mOctreeDirty = true;

		// Request octree reinsertion
		if (mOctree != null)
			mOctree.QueueUpdate(this);
	}

	protected override void OnSceneSet(Scene scene)
	{
		if (scene != null)
		{
			// Register with the scene's octree
			let octree = scene.GetComponent<Octree>();
			if (octree != null)
			{
				mOctree = octree;
				octree.Insert(this);
			}
		}
		else
		{
			// Remove from octree
			if (mOctree != null)
			{
				mOctree.Remove(this);
				mOctree = null;
			}
		}
	}

	protected override void OnRemoved()
	{
		if (mOctree != null)
		{
			mOctree.Remove(this);
			mOctree = null;
		}
	}

	// ===== Private =====

	private void UpdateWorldBoundingBox()
	{
		if (Node != null)
		{
			let worldTransform = Node.WorldTransform;
			// Transform all 8 corners and build a new AABB
			Vector3[] corners = scope .[8];
			mBoundingBox.GetCorners(corners);

			var min = Vector3(float.MaxValue);
			var max = Vector3(float.MinValue);
			for (int i = 0; i < 8; i++)
			{
				let transformed = Vector3.Transform(corners[i], worldTransform);
				min = Vector3.Min(min, transformed);
				max = Vector3.Max(max, transformed);
			}
			mWorldBoundingBox = .(min, max);
		}
		else
		{
			mWorldBoundingBox = mBoundingBox;
		}
		mWorldBoundingBoxDirty = false;
	}
}
