using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// Vertex format for procedural geometry.
public struct ProceduralVertex
{
	public Vector3 Position;
	public Vector3 Normal;
	public Vector2 UV;
	public uint32 Color;

	public this()
	{
		Position = .Zero;
		Normal = .(0, 1, 0);
		UV = .Zero;
		Color = 0xFFFFFFFF;
	}

	public this(Vector3 pos, Vector3 normal, Vector2 uv, uint32 color = 0xFFFFFFFF)
	{
		Position = pos;
		Normal = normal;
		UV = uv;
		Color = color;
	}
}

/// A single sub-geometry within a ProceduralGeometry, with its own material.
struct ProceduralSubGeometry
{
	public int32 StartIndex;
	public int32 IndexCount;
	public MaterialInstance Material;
}

/// Procedural geometry drawable for building meshes at runtime.
///
/// Define vertices and indices programmatically, then call Commit()
/// to generate SourceBatch entries. Supports multiple sub-geometries
/// with separate materials.
///
/// Vertex format: Position(Vec3) + Normal(Vec3) + UV(Vec2) + Color(uint32) = 36 bytes
///
[EngineComponent("Rendering")]
public class ProceduralGeometry : Drawable
{
	private List<ProceduralVertex> mVertices = new .() ~ delete _;
	private List<uint32> mIndices = new .() ~ delete _;
	private List<ProceduralSubGeometry> mSubGeometries = new .() ~ delete _;
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private IBuffer[MAX_FRAMES] mVertexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private IBuffer[MAX_FRAMES] mIndexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private int32[MAX_FRAMES] mLastVertexCounts;
	private int32[MAX_FRAMES] mLastIndexCounts;
	private List<(IBuffer buffer, int32 frameQueued)> mPendingDeletes = new .() ~ { for (var e in _) delete e.buffer; delete _; };
	private int32 mDeferFrameCounter = 0;
	private bool mDirty = true;
	private MaterialInstance mDefaultMaterial;

	// Vertex: Position(Vec3=12) + Normal(Vec3=12) + UV(Vec2=8) + Color(uint32=4) = 36 bytes
	private const int32 VERTEX_SIZE = 36;

	public this()
	{
		SetDrawableType(.Geometry);
	}

	// ===== Properties =====

	/// Number of vertices defined.
	public int32 VertexCount => (int32)mVertices.Count;

	/// Number of indices defined.
	public int32 IndexCount => (int32)mIndices.Count;

	/// Number of sub-geometries.
	public int32 SubGeometryCount => (int32)mSubGeometries.Count;

	/// Default material used when sub-geometries don't specify one.
	public MaterialInstance DefaultMaterial
	{
		get => mDefaultMaterial;
		set => mDefaultMaterial = value;
	}

	// ===== Building API =====

	/// Clears all geometry data. Call before rebuilding.
	public void BeginGeometry()
	{
		mVertices.Clear();
		mIndices.Clear();
		mSubGeometries.Clear();
		mDirty = true;
	}

	/// Adds a vertex and returns its index.
	public uint32 AddVertex(ProceduralVertex vertex)
	{
		let idx = (uint32)mVertices.Count;
		mVertices.Add(vertex);
		mDirty = true;
		return idx;
	}

	/// Adds a vertex with position, normal, UV, and color. Returns its index.
	public uint32 AddVertex(Vector3 position, Vector3 normal, Vector2 uv, uint32 color = 0xFFFFFFFF)
	{
		return AddVertex(ProceduralVertex(position, normal, uv, color));
	}

	/// Adds a triangle by vertex indices.
	public void AddTriangle(uint32 i0, uint32 i1, uint32 i2)
	{
		mIndices.Add(i0);
		mIndices.Add(i1);
		mIndices.Add(i2);
		mDirty = true;
	}

	/// Adds a quad by 4 vertex indices (splits into two triangles).
	public void AddQuad(uint32 i0, uint32 i1, uint32 i2, uint32 i3)
	{
		AddTriangle(i0, i1, i2);
		AddTriangle(i0, i2, i3);
	}

	/// Defines a sub-geometry range with an optional material.
	/// startIndex and indexCount refer to positions in the index buffer.
	public void DefineSubGeometry(int32 startIndex, int32 indexCount, MaterialInstance material = null)
	{
		ProceduralSubGeometry sub = .()
		{
			StartIndex = startIndex,
			IndexCount = indexCount,
			Material = material
		};
		mSubGeometries.Add(sub);
		mDirty = true;
	}

	/// Finalizes geometry: recalculates bounds and marks for GPU upload.
	/// If no sub-geometries were defined, creates one covering all indices.
	public void Commit()
	{
		if (mSubGeometries.Count == 0 && mIndices.Count > 0)
		{
			DefineSubGeometry(0, (int32)mIndices.Count, mDefaultMaterial);
		}

		UpdateBounds();
		mDirty = true;
	}

	// ===== Convenience Shapes =====

	/// Adds a triangle with computed flat normal.
	public void AddTriangle(Vector3 p0, Vector3 p1, Vector3 p2, uint32 color = 0xFFFFFFFF)
	{
		let edge1 = p1 - p0;
		let edge2 = p2 - p0;
		let normal = Vector3.Normalize(Vector3.Cross(edge1, edge2));

		let i0 = AddVertex(p0, normal, .(0, 0), color);
		let i1 = AddVertex(p1, normal, .(1, 0), color);
		let i2 = AddVertex(p2, normal, .(0, 1), color);
		AddTriangle(i0, i1, i2);
	}

	/// Adds a quad from 4 corner positions with computed normal.
	public void AddQuad(Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, uint32 color = 0xFFFFFFFF)
	{
		let edge1 = p1 - p0;
		let edge2 = p3 - p0;
		let normal = Vector3.Normalize(Vector3.Cross(edge1, edge2));

		let i0 = AddVertex(p0, normal, .(0, 1), color);
		let i1 = AddVertex(p1, normal, .(1, 1), color);
		let i2 = AddVertex(p2, normal, .(1, 0), color);
		let i3 = AddVertex(p3, normal, .(0, 0), color);
		AddQuad(i0, i1, i2, i3);
	}

	/// Adds an axis-aligned box.
	public void AddBox(Vector3 center, Vector3 halfExtents, uint32 color = 0xFFFFFFFF)
	{
		let min = center - halfExtents;
		let max = center + halfExtents;

		// 8 corners
		Vector3[8] c;
		c[0] = .(min.X, min.Y, min.Z);
		c[1] = .(max.X, min.Y, min.Z);
		c[2] = .(max.X, max.Y, min.Z);
		c[3] = .(min.X, max.Y, min.Z);
		c[4] = .(min.X, min.Y, max.Z);
		c[5] = .(max.X, min.Y, max.Z);
		c[6] = .(max.X, max.Y, max.Z);
		c[7] = .(min.X, max.Y, max.Z);

		// 6 faces (front, back, left, right, top, bottom)
		AddQuad(c[0], c[1], c[2], c[3], color); // Front (-Z)
		AddQuad(c[5], c[4], c[7], c[6], color); // Back (+Z)
		AddQuad(c[4], c[0], c[3], c[7], color); // Left (-X)
		AddQuad(c[1], c[5], c[6], c[2], color); // Right (+X)
		AddQuad(c[3], c[2], c[6], c[7], color); // Top (+Y)
		AddQuad(c[4], c[5], c[1], c[0], color); // Bottom (-Y)
	}

	// ===== Batch Generation =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (mVertices.Count == 0 || mIndices.Count == 0 || mSubGeometries.Count == 0 || Node == null)
			return;

		let worldTransform = Node.WorldTransform;
		let cameraPos = frameInfo.Camera != null ? frameInfo.Camera.Node.WorldPosition : Vector3.Zero;
		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);

		for (let sub in mSubGeometries)
		{
			SourceBatch batch = .()
			{
				WorldTransform = worldTransform,
				Distance = distance,
				StartIndex = sub.StartIndex,
				IndexCount = sub.IndexCount,
				VertexBuffer = null, // Patched by UploadToGPU with per-frame buffer
				IndexBuffer = null,
				IndexBufferFormat = .UInt32,
				Material = sub.Material != null ? sub.Material : mDefaultMaterial,
				Drawable = this
			};
			MutableBatches.Add(batch);
		}
	}

	/// Uploads procedural geometry to the GPU.
	/// Uses per-frame buffers to avoid destroying buffers still in use by the GPU.
	public Result<void> UploadToGPU(IDevice device, int32 frameIndex)
	{
		if (mVertices.Count == 0 || mIndices.Count == 0)
			return .Ok;

		let fi = frameIndex;
		let vertexCount = (int32)mVertices.Count;
		let indexCount = (int32)mIndices.Count;
		let vertexDataSize = (uint64)(vertexCount * VERTEX_SIZE);
		let indexDataSize = (uint64)(indexCount * 4); // UInt32

		// Flush deferred deletes that have aged past the in-flight window
		FlushDeferredDeletes();

		// Only recreate buffers when capacity is insufficient (grow-only)
		if (mVertexBuffers[fi] == null || vertexCount > mLastVertexCounts[fi] || indexCount > mLastIndexCounts[fi])
		{
			// Defer deletion of old buffers — GPU may still be using them
			if (mVertexBuffers[fi] != null) { mPendingDeletes.Add((mVertexBuffers[fi], mDeferFrameCounter)); mVertexBuffers[fi] = null; }
			if (mIndexBuffers[fi] != null) { mPendingDeletes.Add((mIndexBuffers[fi], mDeferFrameCounter)); mIndexBuffers[fi] = null; }

			// Allocate with 50% headroom to reduce reallocations
			let allocVerts = vertexCount + vertexCount / 2;
			let allocIndices = indexCount + indexCount / 2;
			let allocVBSize = (uint64)(allocVerts * VERTEX_SIZE);
			let allocIBSize = (uint64)(allocIndices * 4); // UInt32

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

			mLastVertexCounts[fi] = allocVerts;
			mLastIndexCounts[fi] = allocIndices;
		}

		// Build vertex data
		let vertexBytes = new uint8[(int)vertexDataSize];
		defer delete vertexBytes;

		for (int32 i = 0; i < vertexCount; i++)
		{
			let v = mVertices[i];
			let offset = i * VERTEX_SIZE;
			*(Vector3*)&vertexBytes[offset] = v.Position;
			*(Vector3*)&vertexBytes[offset + 12] = v.Normal;
			*(Vector2*)&vertexBytes[offset + 24] = v.UV;
			*(uint32*)&vertexBytes[offset + 32] = v.Color;
		}

		device.Queue.WriteBuffer(mVertexBuffers[fi], 0, Span<uint8>(&vertexBytes[0], (int)vertexDataSize));

		// Index data can be written directly from the list's internal buffer
		let indexPtr = mIndices.Ptr;
		device.Queue.WriteBuffer(mIndexBuffers[fi], 0, Span<uint8>((uint8*)indexPtr, (int)indexDataSize));

		// Patch batch entries with current frame's buffer pointers
		for (int32 i = 0; i < MutableBatches.Count; i++)
		{
			MutableBatches[i].VertexBuffer = mVertexBuffers[fi];
			MutableBatches[i].IndexBuffer = mIndexBuffers[fi];
		}

		mDirty = false;
		return .Ok;
	}

	// ===== Private =====

	private void FlushDeferredDeletes()
	{
		mDeferFrameCounter++;
		while (mPendingDeletes.Count > 0 && mDeferFrameCounter - mPendingDeletes[0].frameQueued >= FrameConfig.DELETION_DEFER_FRAMES)
		{
			delete mPendingDeletes[0].buffer;
			mPendingDeletes.RemoveAt(0);
		}
	}

	private void UpdateBounds()
	{
		if (mVertices.Count == 0)
		{
			BoundingBox = .(Vector3(-0.5f), Vector3(0.5f));
			return;
		}

		var min = Vector3(float.MaxValue);
		var max = Vector3(float.MinValue);
		for (let v in mVertices)
		{
			min = Vector3.Min(min, v.Position);
			max = Vector3.Max(max, v.Position);
		}

		// Avoid degenerate box
		let extent = max - min;
		if (extent.X < 0.001f) { min.X -= 0.001f; max.X += 0.001f; }
		if (extent.Y < 0.001f) { min.Y -= 0.001f; max.Y += 0.001f; }
		if (extent.Z < 0.001f) { min.Z -= 0.001f; max.Z += 0.001f; }

		BoundingBox = .(min, max);
	}

	protected override void OnRemoved()
	{
		base.OnRemoved();
	}
}
