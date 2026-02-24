using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.Engine.Animation;
using Sedulous.Geometry;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// Extends StaticModel with skeletal animation support.
///
/// Holds a Skeleton and AnimationPlayer. Each frame, evaluates the animation
/// state and computes skinning matrices for GPU upload. The bone matrix buffer
/// is used by skinned shaders to transform vertices.
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

	// ===== Properties =====

	/// The skeleton for this animated model.
	public Skeleton Skeleton
	{
		get => mSkeleton;
		set
		{
			mSkeleton = value;
			if (value != null)
			{
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

			BufferDescriptor desc = .(dataSize, .Uniform | .CopyDst);
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

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		// Update animation before generating batches
		UpdateAnimation(frameInfo.TimeStep);

		// Generate batches from base StaticModel
		base.UpdateBatches(frameInfo);

		// Attach bone matrix buffer reference to all batches for skinned rendering
		if (mBoneMatrixBuffer != null)
		{
			let batches = Batches;
			for (var batch in ref batches)
				batch.BoneMatrixBuffer = mBoneMatrixBuffer;
		}
	}
}
