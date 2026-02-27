using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.Geometry;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// Data for a single billboard in a BillboardSet.
public struct Billboard
{
	/// Position relative to the owning node.
	public Vector3 Position;
	/// Billboard width and height.
	public Vector2 Size;
	/// Packed RGBA color (use BillboardSet.PackColor to create).
	public uint32 Color;
	/// Rotation around the facing axis (radians).
	public float Rotation;
	/// UV rectangle: (uMin, vMin, uMax, vMax).
	public Vector4 UV;
	/// Whether this billboard is visible.
	public bool Enabled;

	public this()
	{
		Position = .Zero;
		Size = .(1.0f, 1.0f);
		Color = 0xFFFFFFFF;
		Rotation = 0;
		UV = .(0, 0, 1, 1);
		Enabled = true;
	}
}

/// Drawable that renders camera-facing quads.
///
/// Each billboard is a screen-aligned quad positioned relative to the owning
/// node. Billboards are rebuilt each frame to face the active camera.
/// Call UploadToGPU() after UpdateBatches() and before rendering.
///
[EngineComponent("Rendering")]
public class BillboardSet : Drawable
{
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;

	protected List<Billboard> mBillboards = new .() ~ delete _;
	// Per-frame GPU buffers to avoid destroying buffers still in use by previous frames
	private IBuffer[MAX_FRAMES] mVertexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private IBuffer[MAX_FRAMES] mIndexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private int32[MAX_FRAMES] mLastEnabledCounts;
	// Deferred deletion: old buffers kept alive until GPU is guaranteed done with them
	private List<(IBuffer buffer, int32 frameQueued)> mPendingDeletes = new .() ~ { for (var e in _) delete e.buffer; delete _; };
	private int32 mDeferFrameCounter = 0;
	private uint8[] mVertexData ~ delete _;
	private uint8[] mIndexData ~ delete _;
	private List<int32> mSortedIndices = new .() ~ delete _;
	private bool mBuffersDirty = true;
	private MaterialInstance mMaterial;
	private bool mFaceCameraPosition = false;
	private bool mSorted = true;

	// Vertex: Position(Vec3=12) + UV(Vec2=8) + Color(uint32=4) = 24 bytes
	private const int32 VERTEX_SIZE = 24;

	// ===== Properties =====

	/// Number of billboards in this set.
	public int32 BillboardCount => (int32)mBillboards.Count;

	/// The material applied to all billboards.
	public MaterialInstance Material
	{
		get => mMaterial;
		set => mMaterial = value;
	}

	/// If true, each billboard faces the camera position (spherical).
	/// If false, all billboards face the camera direction (screen-aligned).
	public bool FaceCameraPosition
	{
		get => mFaceCameraPosition;
		set => mFaceCameraPosition = value;
	}

	/// If true, billboards are sorted back-to-front for correct alpha blending.
	public bool Sorted
	{
		get => mSorted;
		set => mSorted = value;
	}

	// ===== Billboard Access =====

	/// Resizes the billboard array, adding default billboards or removing extras.
	public void SetBillboardCount(int32 count)
	{
		while (mBillboards.Count < count)
			mBillboards.Add(Billboard());
		while (mBillboards.Count > count)
			mBillboards.PopBack();
		mBuffersDirty = true;
	}

	/// Gets a pointer to a billboard for direct modification.
	/// Call MarkDirty() after modifying.
	public Billboard* GetBillboard(int32 index)
	{
		if (index >= 0 && index < (.)mBillboards.Count)
			return &mBillboards[index];
		return null;
	}

	/// Sets a billboard by value.
	public void SetBillboard(int32 index, Billboard billboard)
	{
		if (index >= 0 && index < (.)mBillboards.Count)
		{
			mBillboards[index] = billboard;
			mBuffersDirty = true;
		}
	}

	/// Marks the billboard geometry as needing rebuild.
	public void MarkDirty()
	{
		mBuffersDirty = true;
	}

	// ===== Batch Generation =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (mBillboards.Count == 0 || Node == null)
			return;

		let cameraNode = frameInfo.Camera?.Node;
		if (cameraNode == null)
			return;

		let cameraPos = cameraNode.WorldPosition;

		// Compute camera-relative right/up vectors
		let cameraRight = cameraNode.WorldRight;
		let cameraUp = cameraNode.WorldUp;

		// Count enabled billboards
		int32 enabledCount = 0;
		for (let bb in mBillboards)
			if (bb.Enabled) enabledCount++;

		if (enabledCount == 0)
			return;

		// Build CPU-side vertex/index data
		BuildGeometry(cameraPos, cameraRight, cameraUp, enabledCount);

		// Update bounding box from billboard positions and sizes (local space)
		UpdateBillboardBounds();

		// Submit a single batch for all billboards.
		// Buffer pointers are set to null here; UploadToGPU patches them
		// with the correct per-frame buffer before batch collection.
		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);
		SourceBatch batch = .()
		{
			WorldTransform = .Identity, // Vertices are already in world space
			Distance = distance,
			StartIndex = 0,
			IndexCount = enabledCount * 6,
			VertexBuffer = null,
			IndexBuffer = null,
			IndexBufferFormat = .UInt16,
			Material = mMaterial,
			Drawable = this
		};
		MutableBatches.Add(batch);
	}

	// ===== GPU Upload =====

	/// Uploads the current billboard geometry to the GPU.
	/// Uses per-frame buffers to avoid destroying buffers still in use by the GPU.
	public Result<void> UploadToGPU(IDevice device, int32 frameIndex)
	{
		int32 enabledCount = 0;
		for (let bb in mBillboards)
			if (bb.Enabled) enabledCount++;

		if (enabledCount == 0)
			return .Ok;

		let fi = frameIndex;
		let vertexDataSize = (uint64)(enabledCount * 4 * VERTEX_SIZE);
		let indexDataSize = (uint64)(enabledCount * 6 * 2);

		// Flush deferred deletes that have aged past the in-flight window
		FlushDeferredDeletes();

		// Only recreate buffers when capacity is insufficient (grow-only)
		if (mVertexBuffers[fi] == null || enabledCount > mLastEnabledCounts[fi])
		{
			// Defer deletion of old buffers — GPU may still be using them
			if (mVertexBuffers[fi] != null) { mPendingDeletes.Add((mVertexBuffers[fi], mDeferFrameCounter)); mVertexBuffers[fi] = null; }
			if (mIndexBuffers[fi] != null) { mPendingDeletes.Add((mIndexBuffers[fi], mDeferFrameCounter)); mIndexBuffers[fi] = null; }

			// Allocate with 50% headroom to reduce reallocations
			let allocCount = enabledCount + enabledCount / 2;
			let allocVBSize = (uint64)(allocCount * 4 * VERTEX_SIZE);
			let allocIBSize = (uint64)(allocCount * 6 * 2);

			BufferDescriptor vbDesc = .(allocVBSize, .Vertex | .CopyDst, .Upload);
			if (device.CreateBuffer(&vbDesc) case .Ok(let vb))
				mVertexBuffers[fi] = vb;
			else
				return .Err;

			BufferDescriptor ibDesc = .(allocIBSize, .Index | .CopyDst, .Upload);
			if (device.CreateBuffer(&ibDesc) case .Ok(let ib))
				mIndexBuffers[fi] = ib;
			else
				return .Err;

			mLastEnabledCounts[fi] = allocCount;
		}

		if (mVertexData != null && vertexDataSize > 0)
			device.Queue.WriteBuffer(mVertexBuffers[fi], 0, Span<uint8>(&mVertexData[0], (int)vertexDataSize));
		if (mIndexData != null && indexDataSize > 0)
			device.Queue.WriteBuffer(mIndexBuffers[fi], 0, Span<uint8>(&mIndexData[0], (int)indexDataSize));

		// Patch batch entries with current frame's buffer pointers
		for (int32 i = 0; i < MutableBatches.Count; i++)
		{
			MutableBatches[i].VertexBuffer = mVertexBuffers[fi];
			MutableBatches[i].IndexBuffer = mIndexBuffers[fi];
		}

		mBuffersDirty = false;
		return .Ok;
	}

	// ===== Helpers =====

	/// Packs normalized RGBA floats (0..1) into a uint32 color.
	public static uint32 PackColor(float r, float g, float b, float a = 1.0f)
	{
		return ((uint32)(Math.Clamp(a, 0, 1) * 255) << 24) |
			   ((uint32)(Math.Clamp(b, 0, 1) * 255) << 16) |
			   ((uint32)(Math.Clamp(g, 0, 1) * 255) << 8) |
			   (uint32)(Math.Clamp(r, 0, 1) * 255);
	}

	// ===== Private =====

	/// Flushes deferred buffer deletes after enough frames have passed
	/// to guarantee the GPU is done with them.
	private void FlushDeferredDeletes()
	{
		mDeferFrameCounter++;
		while (mPendingDeletes.Count > 0 && mDeferFrameCounter - mPendingDeletes[0].frameQueued >= FrameConfig.DELETION_DEFER_FRAMES)
		{
			delete mPendingDeletes[0].buffer;
			mPendingDeletes.RemoveAt(0);
		}
	}

	private void BuildGeometry(Vector3 cameraPos, Vector3 cameraRight, Vector3 cameraUp, int32 enabledCount)
	{
		let vertexDataSize = enabledCount * 4 * VERTEX_SIZE;
		let indexDataSize = enabledCount * 6 * 2; // UInt16

		// Resize CPU buffers if needed
		if (mVertexData == null || mVertexData.Count < vertexDataSize)
		{
			delete mVertexData;
			mVertexData = new uint8[vertexDataSize];
		}
		if (mIndexData == null || mIndexData.Count < indexDataSize)
		{
			delete mIndexData;
			mIndexData = new uint8[indexDataSize];
		}

		let worldTransform = Node.WorldTransform;

		// Build sorted index list
		mSortedIndices.Clear();
		for (int32 i = 0; i < (.)mBillboards.Count; i++)
			if (mBillboards[i].Enabled)
				mSortedIndices.Add(i);

		if (mSorted && mSortedIndices.Count > 1)
		{
			// Sort back-to-front (farthest first) for correct alpha blending
			mSortedIndices.Sort(scope [&] (a, b) =>
			{
				let posA = Vector3.Transform(mBillboards[a].Position, worldTransform);
				let posB = Vector3.Transform(mBillboards[b].Position, worldTransform);
				let da = Vector3.Distance(posA, cameraPos);
				let db = Vector3.Distance(posB, cameraPos);
				return db.CompareTo(da);
			});
		}

		// Generate quads
		for (int32 sortIdx = 0; sortIdx < (.)mSortedIndices.Count; sortIdx++)
		{
			let bb = mBillboards[mSortedIndices[sortIdx]];
			let bbWorldPos = Vector3.Transform(bb.Position, worldTransform);

			// Per-billboard facing vectors (optionally rotated)
			Vector3 right, up;
			if (mFaceCameraPosition)
			{
				// Face toward camera position
				let toCamera = Vector3.Normalize(cameraPos - bbWorldPos);
				right = Vector3.Normalize(Vector3.Cross(cameraUp, toCamera));
				up = Vector3.Cross(toCamera, right);
			}
			else
			{
				right = cameraRight;
				up = cameraUp;
			}

			// Apply per-billboard rotation
			if (bb.Rotation != 0)
			{
				let cos = Math.Cos(bb.Rotation);
				let sin = Math.Sin(bb.Rotation);
				let newRight = right * cos + up * sin;
				let newUp = up * cos - right * sin;
				right = newRight;
				up = newUp;
			}

			let halfX = bb.Size.X * 0.5f;
			let halfY = bb.Size.Y * 0.5f;

			// Quad corners: BL, BR, TR, TL
			Vector3[4] positions;
			positions[0] = bbWorldPos - right * halfX - up * halfY;
			positions[1] = bbWorldPos + right * halfX - up * halfY;
			positions[2] = bbWorldPos + right * halfX + up * halfY;
			positions[3] = bbWorldPos - right * halfX + up * halfY;

			Vector2[4] uvs;
			uvs[0] = .(bb.UV.X, bb.UV.W);
			uvs[1] = .(bb.UV.Z, bb.UV.W);
			uvs[2] = .(bb.UV.Z, bb.UV.Y);
			uvs[3] = .(bb.UV.X, bb.UV.Y);

			// Write 4 vertices
			let baseVertex = sortIdx * 4;
			for (int32 v = 0; v < 4; v++)
			{
				let offset = (baseVertex + v) * VERTEX_SIZE;
				*(Vector3*)&mVertexData[offset] = positions[v];
				*(Vector2*)&mVertexData[offset + 12] = uvs[v];
				*(uint32*)&mVertexData[offset + 20] = bb.Color;
			}

			// Write 6 indices (two triangles)
			let vi = (uint16)baseVertex;
			let idxOffset = sortIdx * 6 * 2;
			uint16* indices = (uint16*)&mIndexData[idxOffset];
			indices[0] = vi;
			indices[1] = vi + 1;
			indices[2] = vi + 2;
			indices[3] = vi;
			indices[4] = vi + 2;
			indices[5] = vi + 3;
		}
	}

	private void UpdateBillboardBounds()
	{
		var min = Vector3(float.MaxValue);
		var max = Vector3(float.MinValue);
		bool anyEnabled = false;

		for (let bb in mBillboards)
		{
			if (!bb.Enabled)
				continue;
			anyEnabled = true;
			let halfSize = Math.Max(bb.Size.X, bb.Size.Y) * 0.5f;
			let expand = Vector3(halfSize);
			min = Vector3.Min(min, bb.Position - expand);
			max = Vector3.Max(max, bb.Position + expand);
		}

		if (anyEnabled)
			BoundingBox = .(min, max);
	}
}
