using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.Geometry;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// A single LOD level for a StaticModel.
public struct ModelLodLevel
{
	/// The mesh geometry for this LOD level.
	public StaticMesh Mesh;
	/// Distance at which this LOD becomes active (0 = highest detail).
	public float Distance;
	/// GPU vertex buffer for this LOD.
	public IBuffer VertexBuffer;
	/// GPU index buffer for this LOD.
	public IBuffer IndexBuffer;
}

/// StaticModel component that renders a mesh with materials and LOD support.
///
/// StaticModel extends Drawable to render static (non-animated) geometry.
/// It holds one or more LOD meshes and generates SourceBatch entries
/// for the appropriate LOD level based on camera distance.
///
[EngineComponent("Rendering")]
public class StaticModel : Drawable
{
	// Primary mesh (LOD 0) — not owned
	private StaticMesh mMesh;

	// GPU buffers for primary mesh (owned)
	private IBuffer mVertexBuffer ~ { if (_ != null) delete _; };
	private IBuffer mIndexBuffer ~ { if (_ != null) delete _; };
	private bool mBuffersDirty = true;

	// LOD levels (beyond LOD 0)
	private List<ModelLodLevel> mLodLevels = new .() ~ {
		for (var lod in _)
		{
			if (lod.VertexBuffer != null) delete lod.VertexBuffer;
			if (lod.IndexBuffer != null) delete lod.IndexBuffer;
		}
		delete _;
	};
	private int32 mCurrentLodLevel = 0;

	// Material instances per sub-mesh (not owned — set by user or resource loader)
	private List<MaterialInstance> mMaterials = new .() ~ delete _;

	public this()
	{
		SetDrawableType(.Geometry);
	}

	// ===== Properties =====

	/// The static mesh geometry (LOD 0).
	public StaticMesh Mesh
	{
		get => mMesh;
		set
		{
			mMesh = value;
			mBuffersDirty = true;
			if (mMesh != null)
				BoundingBox = mMesh.GetBounds();
		}
	}

	/// Number of sub-meshes in the current mesh.
	public int SubMeshCount => mMesh != null ? mMesh.SubMeshes.Count : 0;

	/// The GPU vertex buffer for the primary LOD.
	public IBuffer VertexBuffer => mVertexBuffer;

	/// The GPU index buffer for the primary LOD.
	public IBuffer IndexBuffer => mIndexBuffer;

	/// Number of LOD levels (including the primary mesh as LOD 0).
	public int32 LodLevelCount => 1 + (int32)mLodLevels.Count;

	/// The currently active LOD level (0 = highest detail).
	public int32 CurrentLodLevel => mCurrentLodLevel;

	// ===== LOD Management =====

	/// Adds a LOD level with its mesh and activation distance.
	/// LOD levels should be added in order of increasing distance (decreasing detail).
	public void AddLodLevel(StaticMesh mesh, float distance)
	{
		ModelLodLevel lod = .()
		{
			Mesh = mesh,
			Distance = distance,
			VertexBuffer = null,
			IndexBuffer = null
		};
		mLodLevels.Add(lod);
	}

	/// Removes all LOD levels (keeps the primary mesh as LOD 0).
	public void ClearLodLevels()
	{
		for (var lod in mLodLevels)
		{
			if (lod.VertexBuffer != null) delete lod.VertexBuffer;
			if (lod.IndexBuffer != null) delete lod.IndexBuffer;
		}
		mLodLevels.Clear();
	}

	/// Selects the appropriate LOD level for the given distance.
	/// Returns 0 for highest detail, higher values for lower detail.
	public int32 SelectLodLevel(float distance)
	{
		let adjustedDist = distance / LodBias;

		// Check LOD levels from highest detail to lowest
		for (int32 i = (int32)mLodLevels.Count - 1; i >= 0; i--)
		{
			if (adjustedDist >= mLodLevels[i].Distance)
				return i + 1; // +1 because LOD 0 is the primary mesh
		}
		return 0;
	}

	// ===== Material Management =====

	/// Sets the material instance for a sub-mesh.
	public void SetMaterial(int subMesh, MaterialInstance material)
	{
		while (mMaterials.Count <= subMesh)
			mMaterials.Add(null);
		mMaterials[subMesh] = material;
	}

	/// Sets the same material on all sub-meshes.
	public void SetMaterial(MaterialInstance material)
	{
		int count = SubMeshCount > 0 ? SubMeshCount : 1;
		mMaterials.Clear();
		for (int i = 0; i < count; i++)
			mMaterials.Add(material);
	}

	/// Gets the material instance for a sub-mesh, or null.
	public MaterialInstance GetMaterial(int subMesh)
	{
		if (subMesh >= 0 && subMesh < mMaterials.Count)
			return mMaterials[subMesh];
		return null;
	}

	/// Number of material slots.
	public int MaterialCount => mMaterials.Count;

	// ===== Batch Generation =====

	/// Updates source batches from the current mesh, selecting appropriate LOD.
	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (mMesh == null || Node == null)
			return;

		let worldTransform = Node.WorldTransform;
		let cameraPos = frameInfo.Camera != null ? frameInfo.Camera.Node.WorldPosition : Vector3.Zero;
		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);

		// Select LOD level
		mCurrentLodLevel = SelectLodLevel(distance);

		// Get the mesh, vertex buffer, and index buffer for this LOD
		StaticMesh activeMesh;
		IBuffer activeVB;
		IBuffer activeIB;

		if (mCurrentLodLevel == 0 || mLodLevels.Count == 0)
		{
			activeMesh = mMesh;
			activeVB = mVertexBuffer;
			activeIB = mIndexBuffer;
		}
		else
		{
			let lodIdx = Math.Min(mCurrentLodLevel - 1, (int32)mLodLevels.Count - 1);
			let lod = mLodLevels[lodIdx];
			activeMesh = lod.Mesh != null ? lod.Mesh : mMesh;
			activeVB = lod.VertexBuffer != null ? lod.VertexBuffer : mVertexBuffer;
			activeIB = lod.IndexBuffer != null ? lod.IndexBuffer : mIndexBuffer;
		}

		for (int i = 0; i < activeMesh.SubMeshes.Count; i++)
		{
			let subMesh = activeMesh.SubMeshes[i];
			SourceBatch batch = .()
			{
				WorldTransform = worldTransform,
				Distance = distance,
				StartIndex = subMesh.startIndex,
				IndexCount = subMesh.indexCount,
				VertexBuffer = activeVB,
				IndexBuffer = activeIB,
				IndexBufferFormat = activeMesh.Indices.Format == .UInt16 ? .UInt16 : .UInt32,
				Material = GetMaterial(i),
				Drawable = this
			};
			MutableBatches.Add(batch);
		}
	}

	/// Uploads mesh data to GPU buffers for all LOD levels.
	/// Must be called with a valid device before rendering.
	public Result<void> UploadToGPU(IDevice device)
	{
		// Upload primary mesh (LOD 0)
		if (mMesh != null && mBuffersDirty)
		{
			if (mVertexBuffer != null) { delete mVertexBuffer; mVertexBuffer = null; }
			if (mIndexBuffer != null) { delete mIndexBuffer; mIndexBuffer = null; }

			let vertexData = mMesh.Vertices.GetRawData();
			let vertexSize = (uint64)mMesh.Vertices.GetDataSize();
			if (vertexSize > 0)
			{
				BufferDescriptor vbDesc = .(vertexSize, .Vertex | .CopyDst);
				if (device.CreateBuffer(&vbDesc) case .Ok(let vb))
				{
					mVertexBuffer = vb;
					device.Queue.WriteBuffer(vb, 0, Span<uint8>(vertexData, (int)vertexSize));
				}
				else
					return .Err;
			}

			let indexData = mMesh.Indices.GetRawData();
			let indexSize = (uint64)mMesh.Indices.GetDataSize();
			if (indexSize > 0)
			{
				BufferDescriptor ibDesc = .(indexSize, .Index | .CopyDst);
				if (device.CreateBuffer(&ibDesc) case .Ok(let ib))
				{
					mIndexBuffer = ib;
					device.Queue.WriteBuffer(ib, 0, Span<uint8>(indexData, (int)indexSize));
				}
				else
					return .Err;
			}

			mBuffersDirty = false;
		}

		// Upload LOD meshes
		for (var lod in ref mLodLevels)
		{
			if (lod.Mesh != null && lod.VertexBuffer == null)
			{
				let vertexData = lod.Mesh.Vertices.GetRawData();
				let vertexSize = (uint64)lod.Mesh.Vertices.GetDataSize();
				if (vertexSize > 0)
				{
					BufferDescriptor vbDesc = .(vertexSize, .Vertex | .CopyDst);
					if (device.CreateBuffer(&vbDesc) case .Ok(let vb))
					{
						lod.VertexBuffer = vb;
						device.Queue.WriteBuffer(vb, 0, Span<uint8>(vertexData, (int)vertexSize));
					}
				}

				let indexData = lod.Mesh.Indices.GetRawData();
				let indexSize = (uint64)lod.Mesh.Indices.GetDataSize();
				if (indexSize > 0)
				{
					BufferDescriptor ibDesc = .(indexSize, .Index | .CopyDst);
					if (device.CreateBuffer(&ibDesc) case .Ok(let ib))
					{
						lod.IndexBuffer = ib;
						device.Queue.WriteBuffer(ib, 0, Span<uint8>(indexData, (int)indexSize));
					}
				}
			}
		}

		return .Ok;
	}

	// ===== Raycast =====

	/// More accurate raycast against individual sub-meshes (bounding box level).
	public override void ProcessRayQuery(Ray ray, List<RaycastResult> results)
	{
		// For now, use the base bounding box test
		// TODO: Triangle-level raycast for precise picking
		base.ProcessRayQuery(ray, results);
	}

	protected override void OnRemoved()
	{
		base.OnRemoved();
		// GPU buffers are cleaned up by field destructors
	}
}
