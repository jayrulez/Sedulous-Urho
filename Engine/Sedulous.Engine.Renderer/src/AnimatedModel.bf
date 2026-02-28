using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.Engine.Animation;
using Sedulous.Geometry;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// Extends StaticModel with skeletal animation support.
///
/// Holds a Skeleton and AnimationPlayer. Each frame, evaluates the animation
/// state and computes skinning matrices for GPU upload. The bone matrix buffer
/// is used by skinned shaders to transform vertices.
///
/// Supports both StaticMesh (via base class) and SkinnedMesh (72-byte vertices
/// with joint indices and weights). When a SkinnedMesh is set, vertex/index
/// data is uploaded from it instead of the base StaticMesh.
///
[EngineComponent("Rendering")]
public class AnimatedModel : StaticModel
{
	private Skeleton mSkeleton;
	private AnimationPlayer mAnimPlayer;
	private IBuffer mBoneMatrixBuffer ~ { if (_ != null) delete _; };
	private IBindGroup mBoneBindGroup ~ { if (_ != null) delete _; };
	private bool mBoneBufferDirty = true;
	private int32 mMaxBones = 0;
	private int mLastBoneCount = 0;

	// Skinned mesh (72-byte vertices) — not owned
	private SkinnedMesh mSkinnedMesh;

	// ===== Properties =====

	/// The skinned mesh with joint/weight data for skeletal animation.
	/// When set, vertex/index uploads and batch generation use this instead of the base StaticMesh.
	public SkinnedMesh SkinnedMesh
	{
		get => mSkinnedMesh;
		set
		{
			mSkinnedMesh = value;
			mBuffersDirty = true;
			if (value != null)
				BoundingBox = value.Bounds;
		}
	}

	/// The skeleton for this animated model.
	public Skeleton Skeleton
	{
		get => mSkeleton;
		set
		{
			mSkeleton = value;
			if (value != null)
			{
				if (mAnimPlayer != null)
					delete mAnimPlayer;
				mAnimPlayer = new AnimationPlayer(value);
				mMaxBones = value.BoneCount;
				mBoneBufferDirty = true;
			}
			else
			{
				if (mAnimPlayer != null)
					delete mAnimPlayer;
				mAnimPlayer = null;
				mMaxBones = 0;
			}
		}
	}

	public ~this()
	{
		if (mAnimPlayer != null)
			delete mAnimPlayer;
	}

	/// The animation player for controlling playback.
	public AnimationPlayer AnimPlayer => mAnimPlayer;

	/// Number of bones in the skeleton.
	public int32 BoneCount => mMaxBones;

	/// The GPU buffer holding skinning matrices.
	public IBuffer BoneMatrixBuffer => mBoneMatrixBuffer;

	/// The bind group for bone matrices (slot 3). Created during UploadBoneMatrices.
	public IBindGroup BoneBindGroup => mBoneBindGroup;

	// ===== Animation Control =====

	/// Plays an animation clip.
	public void PlayAnimation(AnimationClip clip, bool restart = true)
	{
		if (mAnimPlayer != null)
			mAnimPlayer.Play(clip, restart);
	}

	/// Stops the current animation.
	public void StopAnimation()
	{
		if (mAnimPlayer != null)
			mAnimPlayer.Stop();
	}

	/// Pauses the current animation.
	public void PauseAnimation()
	{
		if (mAnimPlayer != null)
			mAnimPlayer.Pause();
	}

	/// Resumes a paused animation.
	public void ResumeAnimation()
	{
		if (mAnimPlayer != null)
			mAnimPlayer.Resume();
	}

	/// Blends an additional animation on top of the current one.
	public void BlendAnimation(AnimationClip clip, float time, float weight)
	{
		if (mAnimPlayer != null)
			mAnimPlayer.BlendAnimation(clip, time, weight);
	}

	/// Gets the current skinning matrices for this frame.
	public Span<Matrix> GetSkinningMatrices()
	{
		if (mAnimPlayer != null)
			return mAnimPlayer.GetSkinningMatrices();
		return .();
	}

	/// Sets a specific bone's local transform for procedural animation.
	public void SetBonePose(int32 boneIndex, Transform pose)
	{
		if (mAnimPlayer != null)
			mAnimPlayer.SetBonePose(boneIndex, pose);
	}

	/// Animation playback speed multiplier.
	public float AnimationSpeed
	{
		get => mAnimPlayer != null ? mAnimPlayer.Speed : 1.0f;
		set { if (mAnimPlayer != null) mAnimPlayer.Speed = value; }
	}

	// ===== Update =====

	/// Updates the animation and evaluates skinning matrices.
	/// Call once per frame before rendering.
	public void UpdateAnimation(float deltaTime)
	{
		if (mAnimPlayer == null)
			return;

		mAnimPlayer.Update(deltaTime);
		mAnimPlayer.Evaluate();
		mBoneBufferDirty = true;
	}

	/// Uploads the current skinning matrices to the GPU.
	/// boneLayout: optional bind group layout for bone matrices (slot 3).
	/// When provided, creates/caches a bind group for use during rendering.
	public Result<void> UploadBoneMatrices(IDevice device, IBindGroupLayout boneLayout = null)
	{
		if (mAnimPlayer == null || mMaxBones == 0)
			return .Ok;

		if (!mBoneBufferDirty && mBoneMatrixBuffer != null)
			return .Ok;

		let matrices = mAnimPlayer.GetSkinningMatrices();
		if (matrices.Length == 0)
			return .Ok;

		let dataSize = (uint64)(matrices.Length * sizeof(Matrix));

		// Recreate buffer only if bone count changed or first creation
		if (mBoneMatrixBuffer == null || matrices.Length != mLastBoneCount)
		{
			if (mBoneMatrixBuffer != null)
			{
				delete mBoneMatrixBuffer;
				mBoneMatrixBuffer = null;
			}
			if (mBoneBindGroup != null)
			{
				delete mBoneBindGroup;
				mBoneBindGroup = null;
			}

			BufferDescriptor desc = .(dataSize, .Uniform | .CopyDst, .Upload);
			if (device.CreateBuffer(&desc) case .Ok(let buf))
				mBoneMatrixBuffer = buf;
			else
				return .Err;

			mLastBoneCount = matrices.Length;
		}

		// Upload matrices
		device.Queue.WriteBuffer(mBoneMatrixBuffer, 0, Span<uint8>((uint8*)matrices.Ptr, (int)dataSize));

		// Create bind group if layout provided and not yet created
		if (boneLayout != null && mBoneBindGroup == null && mBoneMatrixBuffer != null)
		{
			BindGroupEntry[1] entries = .(.Buffer(0, mBoneMatrixBuffer, 0, dataSize));
			var bgDesc = BindGroupDescriptor(boneLayout, entries);
			if (device.CreateBindGroup(&bgDesc) case .Ok(let bg))
				mBoneBindGroup = bg;
		}

		mBoneBufferDirty = false;
		return .Ok;
	}

	// ===== Overrides =====

	/// Uploads vertex/index data to GPU. When a SkinnedMesh is set, uploads its
	/// 72-byte vertex data; otherwise falls through to base StaticModel upload.
	public override Result<void> UploadToGPU(IDevice device)
	{
		if (mSkinnedMesh != null && mBuffersDirty)
		{
			if (mVertexBuffer != null) { delete mVertexBuffer; mVertexBuffer = null; }
			if (mIndexBuffer != null) { delete mIndexBuffer; mIndexBuffer = null; }

			let vertexData = mSkinnedMesh.GetVertexData();
			let vertexSize = (uint64)(mSkinnedMesh.VertexCount * mSkinnedMesh.VertexSize);
			if (vertexSize > 0 && vertexData != null)
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

			let indexData = mSkinnedMesh.GetIndexData();
			let indexSize = (uint64)mSkinnedMesh.Indices.GetDataSize();
			if (indexSize > 0 && indexData != null)
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
			return .Ok;
		}

		return base.UploadToGPU(device);
	}

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		// Update animation before generating batches
		UpdateAnimation(frameInfo.TimeStep);

		if (mSkinnedMesh != null)
		{
			// Generate batches from skinned mesh
			MutableBatches.Clear();

			if (Node == null)
				return;

			let worldTransform = Node.WorldTransform;
			let cameraPos = frameInfo.Camera != null ? frameInfo.Camera.Node.WorldPosition : Vector3.Zero;
			let distance = Vector3.Distance(Node.WorldPosition, cameraPos);

			let isIndexed = mIndexBuffer != null && mSkinnedMesh.Indices.GetDataSize() > 0;
			for (int i = 0; i < mSkinnedMesh.SubMeshes.Count; i++)
			{
				let subMesh = mSkinnedMesh.SubMeshes[i];
				SourceBatch batch = .()
				{
					WorldTransform = worldTransform,
					Distance = distance,
					StartIndex = isIndexed ? subMesh.startIndex : 0,
					IndexCount = isIndexed ? subMesh.indexCount : 0,
					VertexCount = isIndexed ? 0 : mSkinnedMesh.VertexCount,
					VertexBuffer = mVertexBuffer,
					IndexBuffer = isIndexed ? mIndexBuffer : null,
					IndexBufferFormat = isIndexed ? (mSkinnedMesh.Indices.Format == .UInt16 ? .UInt16 : .UInt32) : .UInt16,
					Material = GetMaterial(i),
					Drawable = this,
					BoneMatrixBuffer = mBoneMatrixBuffer
				};
				MutableBatches.Add(batch);
			}
		}
		else
		{
			// Fall through to StaticModel path
			base.UpdateBatches(frameInfo);

			// Attach bone matrix buffer to all batches for skinned rendering
			if (mBoneMatrixBuffer != null)
			{
				let batches = Batches;
				for (var batch in ref batches)
					batch.BoneMatrixBuffer = mBoneMatrixBuffer;
			}
		}
	}
}
