using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// A terrain patch for chunked rendering.
public struct TerrainPatch
{
	/// Local-space bounding box for this patch.
	public BoundingBox Bounds;
	/// Start index in the terrain index buffer.
	public int32 StartIndex;
	/// Number of indices for this patch.
	public int32 IndexCount;
	/// LOD level (0 = highest detail).
	public int32 LodLevel;
}

/// Heightmap-based terrain component with chunked LOD.
///
/// Generates terrain geometry from a heightmap array. The terrain is
/// divided into patches for frustum culling and LOD selection.
/// Vertices are Position(Vec3) + Normal(Vec3) + UV(Vec2) = 32 bytes.
///
[EngineComponent("Rendering")]
public class Terrain : Drawable
{
	// Heightmap data
	private float[] mHeightData ~ delete _;
	private int32 mHeightMapWidth = 0;
	private int32 mHeightMapHeight = 0;

	// Terrain dimensions
	private Vector3 mSpacing = .(1.0f, 1.0f, 1.0f);
	private int32 mPatchSize = 32;
	private int32 mMaxLodLevels = 4;

	// Patches
	private List<TerrainPatch> mPatches = new .() ~ delete _;
	private int32 mPatchesX = 0;
	private int32 mPatchesZ = 0;

	// GPU buffers (per-frame to avoid destroying buffers still in use by previous frames)
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private IBuffer[MAX_FRAMES] mVertexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private IBuffer[MAX_FRAMES] mIndexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private uint8[] mVertexData ~ delete _;
	private uint8[] mIndexData ~ delete _;
	private bool mBuffersDirty = true;
	private int32 mTotalVertices = 0;
	private int32 mTotalIndices = 0;

	// Material
	private MaterialInstance mMaterial;

	// Vertex: Position(Vec3=12) + Normal(Vec3=12) + UV(Vec2=8) = 32 bytes
	private const int32 VERTEX_SIZE = 32;

	public this()
	{
		SetDrawableType(.Geometry);
	}

	// ===== Properties =====

	/// Spacing between vertices (X = horizontal, Y = height scale, Z = depth).
	[Editable("Spacing X")]
	public float SpacingX
	{
		get => mSpacing.X;
		set => mSpacing.X = Math.Max(value, 0.01f);
	}

	[Editable("Spacing Y")]
	public float SpacingY
	{
		get => mSpacing.Y;
		set => mSpacing.Y = Math.Max(value, 0.01f);
	}

	[Editable("Spacing Z")]
	public float SpacingZ
	{
		get => mSpacing.Z;
		set => mSpacing.Z = Math.Max(value, 0.01f);
	}

	/// Vertex spacing as a vector.
	public Vector3 Spacing
	{
		get => mSpacing;
		set => mSpacing = value;
	}

	/// Size of each terrain patch in vertices (e.g. 32 means 32x32 vertices per patch).
	[Editable("Patch Size")]
	public int32 PatchSize
	{
		get => mPatchSize;
		set => mPatchSize = Math.Clamp(value, 4, 128);
	}

	/// Maximum number of LOD levels.
	[Editable("Max LOD Levels")]
	public int32 MaxLodLevels
	{
		get => mMaxLodLevels;
		set => mMaxLodLevels = Math.Clamp(value, 1, 8);
	}

	/// Width of the heightmap in samples.
	public int32 HeightMapWidth => mHeightMapWidth;

	/// Height of the heightmap in samples.
	public int32 HeightMapHeight => mHeightMapHeight;

	/// Number of terrain patches.
	public int32 PatchCount => (int32)mPatches.Count;

	/// The material applied to the terrain.
	public MaterialInstance Material
	{
		get => mMaterial;
		set => mMaterial = value;
	}

	// ===== Heightmap =====

	/// Sets the heightmap from a flat array of height values.
	/// width/height are the number of samples in X and Z.
	/// Heights are in the range [0, 1] and scaled by Spacing.Y.
	public void SetHeightMap(Span<float> heights, int32 width, int32 height)
	{
		delete mHeightData;
		mHeightMapWidth = width;
		mHeightMapHeight = height;
		mHeightData = new float[width * height];
		heights.CopyTo(mHeightData);

		RebuildGeometry();
	}

	/// Gets the height at grid coordinates.
	public float GetHeight(int32 x, int32 z)
	{
		if (mHeightData == null || x < 0 || x >= mHeightMapWidth || z < 0 || z >= mHeightMapHeight)
			return 0;
		return mHeightData[z * mHeightMapWidth + x];
	}

	/// Sets the height at grid coordinates and marks geometry dirty.
	public void SetHeight(int32 x, int32 z, float height)
	{
		if (mHeightData == null || x < 0 || x >= mHeightMapWidth || z < 0 || z >= mHeightMapHeight)
			return;
		mHeightData[z * mHeightMapWidth + x] = height;
		mBuffersDirty = true;
	}

	/// Gets the interpolated height at a world-space XZ position.
	public float GetWorldHeight(float worldX, float worldZ)
	{
		if (mHeightData == null)
			return 0;

		// Convert world position to grid coordinates
		let nodePos = Node?.WorldPosition ?? .Zero;
		let localX = (worldX - nodePos.X) / mSpacing.X;
		let localZ = (worldZ - nodePos.Z) / mSpacing.Z;

		// Bilinear interpolation
		let ix = (int32)Math.Floor(localX);
		let iz = (int32)Math.Floor(localZ);
		let fx = localX - ix;
		let fz = localZ - iz;

		let h00 = GetHeight(ix, iz);
		let h10 = GetHeight(ix + 1, iz);
		let h01 = GetHeight(ix, iz + 1);
		let h11 = GetHeight(ix + 1, iz + 1);

		let h0 = h00 + (h10 - h00) * fx;
		let h1 = h01 + (h11 - h01) * fx;

		return (h0 + (h1 - h0) * fz) * mSpacing.Y + nodePos.Y;
	}

	// ===== Batch Generation =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (mHeightData == null || mPatches.Count == 0 || Node == null)
			return;

		let worldTransform = Node.WorldTransform;
		let cameraNode = frameInfo.Camera?.Node;
		let cameraPos = cameraNode != null ? cameraNode.WorldPosition : Vector3.Zero;
		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);

		// Submit one batch per patch (enables per-patch frustum culling)
		for (let patch in mPatches)
		{
			SourceBatch batch = .()
			{
				WorldTransform = worldTransform,
				Distance = distance,
				StartIndex = patch.StartIndex,
				IndexCount = patch.IndexCount,
				VertexBuffer = null, // Patched by UploadToGPU with per-frame buffer
				IndexBuffer = null,
				IndexBufferFormat = .UInt32,
				Material = mMaterial,
				Drawable = this
			};
			MutableBatches.Add(batch);
		}
	}

	// ===== GPU Upload =====

	/// Uploads terrain geometry to the GPU.
	/// Uses per-frame buffers to avoid destroying buffers still in use by the GPU.
	/// Only recreates buffers when geometry has changed (mBuffersDirty).
	public Result<void> UploadToGPU(IDevice device, int32 frameIndex)
	{
		if (mHeightData == null)
			return .Ok;

		let needsRebuild = mBuffersDirty;
		if (needsRebuild)
			RebuildGeometry();

		if (mTotalVertices == 0 || mTotalIndices == 0)
			return .Ok;

		let fi = frameIndex;

		// Only recreate and re-upload buffers when geometry data changed
		if (needsRebuild || mVertexBuffers[fi] == null || mIndexBuffers[fi] == null)
		{
			let vertexDataSize = (uint64)(mTotalVertices * VERTEX_SIZE);
			let indexDataSize = (uint64)(mTotalIndices * 4); // UInt32

			if (mVertexBuffers[fi] != null) { delete mVertexBuffers[fi]; mVertexBuffers[fi] = null; }
			if (mIndexBuffers[fi] != null) { delete mIndexBuffers[fi]; mIndexBuffers[fi] = null; }

			BufferDescriptor vbDesc = .(vertexDataSize, .Vertex | .CopyDst, .Upload);
			if (device.CreateBuffer(&vbDesc) case .Ok(let vb))
				mVertexBuffers[fi] = vb;
			else
				return .Err;

			BufferDescriptor ibDesc = .(indexDataSize, .Index | .CopyDst, .Upload);
			if (device.CreateBuffer(&ibDesc) case .Ok(let ib))
				mIndexBuffers[fi] = ib;
			else
				return .Err;

			if (mVertexData != null && vertexDataSize > 0)
				device.Queue.WriteBuffer(mVertexBuffers[fi], 0, Span<uint8>(&mVertexData[0], (int)vertexDataSize));
			if (mIndexData != null && indexDataSize > 0)
				device.Queue.WriteBuffer(mIndexBuffers[fi], 0, Span<uint8>(&mIndexData[0], (int)indexDataSize));

			mBuffersDirty = false;
		}

		// Always patch batch entries with current frame's buffer pointers
		for (int32 i = 0; i < MutableBatches.Count; i++)
		{
			MutableBatches[i].VertexBuffer = mVertexBuffers[fi];
			MutableBatches[i].IndexBuffer = mIndexBuffers[fi];
		}

		return .Ok;
	}

	// ===== Geometry Helpers =====

	/// Gets the terrain vertex/index data as triangle soup for navigation mesh building.
	/// outVertices: filled with x,y,z triples. outIndices: filled with triangle indices.
	public void GetTriangleData(List<float> outVertices, List<int32> outIndices)
	{
		if (mHeightData == null)
			return;

		let w = mHeightMapWidth;
		let h = mHeightMapHeight;

		for (int32 z = 0; z < h; z++)
		{
			for (int32 x = 0; x < w; x++)
			{
				outVertices.Add(x * mSpacing.X);
				outVertices.Add(mHeightData[z * w + x] * mSpacing.Y);
				outVertices.Add(z * mSpacing.Z);
			}
		}

		for (int32 z = 0; z < h - 1; z++)
		{
			for (int32 x = 0; x < w - 1; x++)
			{
				let i00 = z * w + x;
				let i10 = z * w + x + 1;
				let i01 = (z + 1) * w + x;
				let i11 = (z + 1) * w + x + 1;

				outIndices.Add(i00);
				outIndices.Add(i01);
				outIndices.Add(i10);

				outIndices.Add(i10);
				outIndices.Add(i01);
				outIndices.Add(i11);
			}
		}
	}

	// ===== Private =====

	private void RebuildGeometry()
	{
		mPatches.Clear();

		if (mHeightData == null || mHeightMapWidth < 2 || mHeightMapHeight < 2)
		{
			mTotalVertices = 0;
			mTotalIndices = 0;
			return;
		}

		let w = mHeightMapWidth;
		let h = mHeightMapHeight;

		// Calculate patch layout
		mPatchesX = (w - 1 + mPatchSize - 1) / mPatchSize;
		mPatchesZ = (h - 1 + mPatchSize - 1) / mPatchSize;

		// Total vertices = full grid (shared between patches)
		mTotalVertices = w * h;

		// Count indices: each patch is a grid of quads, 2 triangles each
		mTotalIndices = 0;
		for (int32 pz = 0; pz < mPatchesZ; pz++)
		{
			for (int32 px = 0; px < mPatchesX; px++)
			{
				let startX = px * mPatchSize;
				let startZ = pz * mPatchSize;
				let endX = Math.Min(startX + mPatchSize, w - 1);
				let endZ = Math.Min(startZ + mPatchSize, h - 1);
				let patchQuadsX = endX - startX;
				let patchQuadsZ = endZ - startZ;
				mTotalIndices += patchQuadsX * patchQuadsZ * 6;
			}
		}

		// Build vertex data
		let vertexDataSize = mTotalVertices * VERTEX_SIZE;
		delete mVertexData;
		mVertexData = new uint8[vertexDataSize];

		for (int32 z = 0; z < h; z++)
		{
			for (int32 x = 0; x < w; x++)
			{
				let idx = z * w + x;
				let offset = idx * VERTEX_SIZE;

				// Position
				let px = x * mSpacing.X;
				let py = mHeightData[idx] * mSpacing.Y;
				let pz = z * mSpacing.Z;
				*(Vector3*)&mVertexData[offset] = .(px, py, pz);

				// Normal (from central differences)
				let normal = CalculateNormal(x, z);
				*(Vector3*)&mVertexData[offset + 12] = normal;

				// UV
				let u = (float)x / (float)(w - 1);
				let v = (float)z / (float)(h - 1);
				*(Vector2*)&mVertexData[offset + 24] = .(u, v);
			}
		}

		// Build index data per patch
		let indexDataSize = mTotalIndices * 4; // UInt32
		delete mIndexData;
		mIndexData = new uint8[indexDataSize];

		int32 indexOffset = 0;
		for (int32 pz = 0; pz < mPatchesZ; pz++)
		{
			for (int32 px2 = 0; px2 < mPatchesX; px2++)
			{
				let startX = px2 * mPatchSize;
				let startZ = pz * mPatchSize;
				let endX = Math.Min(startX + mPatchSize, w - 1);
				let endZ = Math.Min(startZ + mPatchSize, h - 1);

				let patchStartIndex = indexOffset;

				for (int32 z = startZ; z < endZ; z++)
				{
					for (int32 x = startX; x < endX; x++)
					{
						let i00 = (uint32)(z * w + x);
						let i10 = (uint32)(z * w + x + 1);
						let i01 = (uint32)((z + 1) * w + x);
						let i11 = (uint32)((z + 1) * w + x + 1);

						uint32* indices = (uint32*)&mIndexData[indexOffset * 4];
						indices[0] = i00;
						indices[1] = i01;
						indices[2] = i10;
						indices[3] = i10;
						indices[4] = i01;
						indices[5] = i11;
						indexOffset += 6;
					}
				}

				// Create patch info
				let patchIdxCount = indexOffset - patchStartIndex;

				// Calculate patch bounds
				var patchMin = Vector3(float.MaxValue);
				var patchMax = Vector3(float.MinValue);
				for (int32 z = startZ; z <= Math.Min(startZ + mPatchSize, h - 1); z++)
				{
					for (int32 x = startX; x <= Math.Min(startX + mPatchSize, w - 1); x++)
					{
						let vx = x * mSpacing.X;
						let vy = mHeightData[z * w + x] * mSpacing.Y;
						let vz = z * mSpacing.Z;
						patchMin = Vector3.Min(patchMin, .(vx, vy, vz));
						patchMax = Vector3.Max(patchMax, .(vx, vy, vz));
					}
				}

				TerrainPatch patch = .()
				{
					Bounds = .(patchMin, patchMax),
					StartIndex = patchStartIndex,
					IndexCount = patchIdxCount,
					LodLevel = 0
				};
				mPatches.Add(patch);
			}
		}

		// Update overall bounding box
		var terrainMin = Vector3(0, float.MaxValue, 0);
		var terrainMax = Vector3((w - 1) * mSpacing.X, float.MinValue, (h - 1) * mSpacing.Z);
		for (int32 i = 0; i < w * h; i++)
		{
			let hy = mHeightData[i] * mSpacing.Y;
			if (hy < terrainMin.Y) terrainMin.Y = hy;
			if (hy > terrainMax.Y) terrainMax.Y = hy;
		}
		BoundingBox = .(terrainMin, terrainMax);

		mBuffersDirty = true;
	}

	private Vector3 CalculateNormal(int32 x, int32 z)
	{
		let w = mHeightMapWidth;
		let h = mHeightMapHeight;

		let hL = GetHeight(Math.Max(x - 1, 0), z) * mSpacing.Y;
		let hR = GetHeight(Math.Min(x + 1, w - 1), z) * mSpacing.Y;
		let hD = GetHeight(x, Math.Max(z - 1, 0)) * mSpacing.Y;
		let hU = GetHeight(x, Math.Min(z + 1, h - 1)) * mSpacing.Y;

		let dx = hL - hR;
		let dz = hD - hU;

		// Tangent spacing
		let sx = (x > 0 && x < w - 1) ? mSpacing.X * 2 : mSpacing.X;
		let sz = (z > 0 && z < h - 1) ? mSpacing.Z * 2 : mSpacing.Z;

		return Vector3.Normalize(.(dx / sx, 1.0f, dz / sz));
	}
}
