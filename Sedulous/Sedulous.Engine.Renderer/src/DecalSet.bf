using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// Data for a single decal in a DecalSet.
public struct Decal
{
	/// World-space position where the decal is projected.
	public Vector3 Position;
	/// Surface normal at the decal location.
	public Vector3 Normal;
	/// Tangent vector for decal orientation.
	public Vector3 Tangent;
	/// Half-size of the decal quad.
	public Vector2 HalfSize;
	/// UV rectangle: (uMin, vMin, uMax, vMax).
	public Vector4 UV;
	/// Time-to-live in seconds (0 = permanent).
	public float TimeToLive;
	/// Time this decal has been alive.
	public float TimeAlive;
	/// Packed RGBA color.
	public uint32 Color;
	/// Whether this decal is active.
	public bool Enabled;
}

/// Drawable that renders projected decals on surfaces.
///
/// Decals are small quads placed on surfaces (walls, floors, etc.) to
/// represent bullet holes, scorch marks, blood splatters, etc. Each decal
/// is a screen-aligned quad projected along the surface normal.
///
/// Vertex: Position(Vec3=12) + Normal(Vec3=12) + UV(Vec2=8) + Color(uint32=4) = 36 bytes
///
[EngineComponent("Rendering")]
public class DecalSet : Drawable
{
	private List<Decal> mDecals = new .() ~ delete _;
	private int32 mMaxDecals = 64;

	// GPU buffers (per-frame to avoid destroying buffers still in use by previous frames)
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private IBuffer[MAX_FRAMES] mVertexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private IBuffer[MAX_FRAMES] mIndexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private uint8[] mVertexData ~ delete _;
	private uint8[] mIndexData ~ delete _;
	private int32[MAX_FRAMES] mLastEnabledCounts;
	private bool mBuffersDirty = true;

	// Material
	private MaterialInstance mMaterial;

	// Vertex: Position(Vec3=12) + Normal(Vec3=12) + UV(Vec2=8) + Color(uint32=4) = 36 bytes
	private const int32 VERTEX_SIZE = 36;

	public this()
	{
		SetDrawableType(.Geometry);
	}

	// ===== Properties =====

	/// Maximum number of decals this set can hold.
	[Editable("Max Decals")]
	public int32 MaxDecals
	{
		get => mMaxDecals;
		set => mMaxDecals = Math.Max(value, 1);
	}

	/// Number of currently active decals.
	public int32 ActiveDecalCount
	{
		get
		{
			int32 count = 0;
			for (let d in mDecals)
				if (d.Enabled) count++;
			return count;
		}
	}

	/// Total decals (including disabled).
	public int32 DecalCount => (int32)mDecals.Count;

	/// The material applied to all decals.
	public MaterialInstance Material
	{
		get => mMaterial;
		set => mMaterial = value;
	}

	// ===== Decal Management =====

	/// Adds a decal at the given position and orientation.
	/// Returns the index of the new decal, or -1 if at capacity.
	public int32 AddDecal(Vector3 position, Vector3 normal, float size, float timeToLive = 0)
	{
		return AddDecal(position, normal, .(size * 0.5f, size * 0.5f), .(0, 0, 1, 1), 0xFFFFFFFF, timeToLive);
	}

	/// Adds a decal with full control over parameters.
	public int32 AddDecal(Vector3 position, Vector3 normal, Vector2 halfSize, Vector4 uv, uint32 color, float timeToLive = 0)
	{
		// Find a free slot or remove oldest if at capacity
		int32 slot = -1;
		for (int32 i = 0; i < (int32)mDecals.Count; i++)
		{
			if (!mDecals[i].Enabled)
			{
				slot = i;
				break;
			}
		}

		if (slot < 0)
		{
			if (mDecals.Count < mMaxDecals)
			{
				slot = (int32)mDecals.Count;
				mDecals.Add(.());
			}
			else
			{
				// Remove oldest (first) decal
				slot = 0;
			}
		}

		// Calculate tangent from normal
		let tangent = CalculateTangent(normal);

		Decal decal = .()
		{
			Position = position,
			Normal = normal,
			Tangent = tangent,
			HalfSize = halfSize,
			UV = uv,
			TimeToLive = timeToLive,
			TimeAlive = 0,
			Color = color,
			Enabled = true
		};
		mDecals[slot] = decal;
		mBuffersDirty = true;

		return slot;
	}

	/// Removes a decal by index.
	public void RemoveDecal(int32 index)
	{
		if (index >= 0 && index < (int32)mDecals.Count)
		{
			mDecals[index].Enabled = false;
			mBuffersDirty = true;
		}
	}

	/// Removes all decals.
	public void RemoveAllDecals()
	{
		mDecals.Clear();
		mBuffersDirty = true;
	}

	// ===== Batch Generation =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (mDecals.Count == 0 || Node == null)
			return;

		let dt = frameInfo.TimeStep;

		// Age decals and remove expired ones
		for (int32 i = (int32)mDecals.Count - 1; i >= 0; i--)
		{
			if (!mDecals[i].Enabled)
				continue;

			if (mDecals[i].TimeToLive > 0)
			{
				mDecals[i].TimeAlive += dt;
				if (mDecals[i].TimeAlive >= mDecals[i].TimeToLive)
				{
					mDecals[i].Enabled = false;
					mBuffersDirty = true;
					continue;
				}
			}
		}

		// Count enabled
		int32 enabledCount = 0;
		for (let d in mDecals)
			if (d.Enabled) enabledCount++;

		if (enabledCount == 0)
			return;

		// Build geometry if needed
		if (mBuffersDirty)
			BuildGeometry(enabledCount);

		let cameraNode = frameInfo.Camera?.Node;
		let cameraPos = cameraNode != null ? cameraNode.WorldPosition : Vector3.Zero;
		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);

		SourceBatch batch = .()
		{
			WorldTransform = .Identity, // Decal vertices are in world space
			Distance = distance,
			StartIndex = 0,
			IndexCount = enabledCount * 6,
			VertexBuffer = null, // Patched by UploadToGPU with per-frame buffer
			IndexBuffer = null,
			IndexBufferFormat = .UInt16,
			Material = mMaterial,
			Drawable = this
		};
		MutableBatches.Add(batch);
	}

	// ===== GPU Upload =====

	/// Uploads decal geometry to the GPU.
	/// Uses per-frame buffers to avoid destroying buffers still in use by the GPU.
	public Result<void> UploadToGPU(IDevice device, int32 frameIndex)
	{
		int32 enabledCount = 0;
		for (let d in mDecals)
			if (d.Enabled) enabledCount++;

		if (enabledCount == 0)
			return .Ok;

		let fi = frameIndex;
		let vertexDataSize = (uint64)(enabledCount * 4 * VERTEX_SIZE);
		let indexDataSize = (uint64)(enabledCount * 6 * 2); // UInt16

		// Recreate this frame's buffers if count changed
		if (mVertexBuffers[fi] == null || mLastEnabledCounts[fi] != enabledCount)
		{
			if (mVertexBuffers[fi] != null) { delete mVertexBuffers[fi]; mVertexBuffers[fi] = null; }
			if (mIndexBuffers[fi] != null) { delete mIndexBuffers[fi]; mIndexBuffers[fi] = null; }

			BufferDescriptor vbDesc = .(vertexDataSize, .Vertex | .CopyDst);
			if (device.CreateBuffer(&vbDesc) case .Ok(let vb))
				mVertexBuffers[fi] = vb;
			else
				return .Err;

			BufferDescriptor ibDesc = .(indexDataSize, .Index | .CopyDst);
			if (device.CreateBuffer(&ibDesc) case .Ok(let ib))
				mIndexBuffers[fi] = ib;
			else
				return .Err;

			mLastEnabledCounts[fi] = enabledCount;
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

	// ===== Private =====

	private void BuildGeometry(int32 enabledCount)
	{
		let vertexDataSize = enabledCount * 4 * VERTEX_SIZE;
		let indexDataSize = enabledCount * 6 * 2; // UInt16

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

		int32 quadIdx = 0;
		for (let decal in mDecals)
		{
			if (!decal.Enabled)
				continue;

			let bitangent = Vector3.Cross(decal.Normal, decal.Tangent);
			let right = decal.Tangent * decal.HalfSize.X;
			let up = bitangent * decal.HalfSize.Y;

			// Offset slightly along normal to avoid z-fighting
			let pos = decal.Position + decal.Normal * 0.002f;

			// Quad corners: BL, BR, TR, TL
			Vector3[4] positions = .(
				pos - right - up,
				pos + right - up,
				pos + right + up,
				pos - right + up
			);

			Vector2[4] uvs = .(
				.(decal.UV.X, decal.UV.W),
				.(decal.UV.Z, decal.UV.W),
				.(decal.UV.Z, decal.UV.Y),
				.(decal.UV.X, decal.UV.Y)
			);

			// Write 4 vertices
			let baseVertex = quadIdx * 4;
			for (int32 v = 0; v < 4; v++)
			{
				let offset = (baseVertex + v) * VERTEX_SIZE;
				*(Vector3*)&mVertexData[offset] = positions[v];
				*(Vector3*)&mVertexData[offset + 12] = decal.Normal;
				*(Vector2*)&mVertexData[offset + 24] = uvs[v];
				*(uint32*)&mVertexData[offset + 32] = decal.Color;
			}

			// Write 6 indices (two triangles)
			let vi = (uint16)baseVertex;
			let idxOffset = quadIdx * 6 * 2;
			uint16* indices = (uint16*)&mIndexData[idxOffset];
			indices[0] = vi;
			indices[1] = vi + 1;
			indices[2] = vi + 2;
			indices[3] = vi;
			indices[4] = vi + 2;
			indices[5] = vi + 3;

			quadIdx++;
		}
	}

	private static Vector3 CalculateTangent(Vector3 normal)
	{
		// Choose a reference vector that isn't parallel to the normal
		let refVec = Math.Abs(Vector3.Dot(normal, .(0, 1, 0))) > 0.9f
			? Vector3(1, 0, 0)
			: Vector3(0, 1, 0);
		return Vector3.Normalize(Vector3.Cross(refVec, normal));
	}
}
