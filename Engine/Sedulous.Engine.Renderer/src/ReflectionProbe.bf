using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// When the reflection probe captures its cubemap.
public enum ReflectionProbeMode
{
	/// Captured once at startup and whenever manually triggered.
	Baked,
	/// Re-captured every frame (expensive).
	Realtime,
	/// Captured once and then only on demand via RequestUpdate().
	OnDemand
}

/// Reflection probe component that captures a cubemap at its position.
///
/// Used for local reflections and specular IBL. The probe captures
/// six faces of a cubemap from its node's world position. Drawables
/// within the probe's influence volume use this cubemap for reflections
/// instead of the global environment map.
///
/// Box projection remaps reflection rays to account for the finite
/// volume of the probe, producing more accurate indoor reflections.
///
[EngineComponent("Rendering")]
public class ReflectionProbe : Component
{
	private ReflectionProbeMode mMode = .Baked;
	private int32 mResolution = 256;
	private float mNearClip = 0.1f;
	private float mFarClip = 1000.0f;
	private int32 mPriority = 0;

	// Influence volume (world-space, centered on node)
	private Vector3 mBoxExtents = .(5.0f, 5.0f, 5.0f);
	private Vector3 mBoxOffset = .Zero;
	private bool mBoxProjection = false;
	private float mBlendDistance = 1.0f;

	// Intensity
	private float mIntensity = 1.0f;

	// Captured cubemap (owned by this probe)
	private ITextureView mCubemapView;
	private ITexture mCubemapTexture ~ { if (_ != null) delete _; };
	private bool mNeedsUpdate = true;
	private uint64 mLastUpdateFrame = 0;

	// ===== Properties =====

	/// Capture mode.
	public ReflectionProbeMode Mode
	{
		get => mMode;
		set => mMode = value;
	}

	/// Cubemap face resolution in pixels.
	public int32 Resolution
	{
		get => mResolution;
		set => mResolution = Math.Max(value, 16);
	}

	/// Near clip plane for capture cameras.
	public float NearClip
	{
		get => mNearClip;
		set => mNearClip = Math.Max(value, 0.001f);
	}

	/// Far clip plane for capture cameras.
	public float FarClip
	{
		get => mFarClip;
		set => mFarClip = Math.Max(value, mNearClip + 0.1f);
	}

	/// Priority for overlapping probes (higher wins).
	public int32 Priority
	{
		get => mPriority;
		set => mPriority = value;
	}

	/// Half-extents of the influence box (local space).
	public Vector3 BoxExtents
	{
		get => mBoxExtents;
		set => mBoxExtents = value;
	}

	/// Offset of the influence box center from the node position.
	public Vector3 BoxOffset
	{
		get => mBoxOffset;
		set => mBoxOffset = value;
	}

	/// Whether to use box projection for more accurate indoor reflections.
	public bool BoxProjection
	{
		get => mBoxProjection;
		set => mBoxProjection = value;
	}

	/// Blend distance at the edges of the influence volume (meters).
	public float BlendDistance
	{
		get => mBlendDistance;
		set => mBlendDistance = Math.Max(value, 0.0f);
	}

	/// Intensity multiplier for the reflection.
	public float Intensity
	{
		get => mIntensity;
		set => mIntensity = Math.Max(value, 0.0f);
	}

	/// The captured cubemap texture view, or null if not yet captured.
	public ITextureView CubemapView => mCubemapView;

	/// Whether this probe needs to re-capture.
	public bool NeedsUpdate => mNeedsUpdate;

	/// Frame number of the last capture.
	public uint64 LastUpdateFrame => mLastUpdateFrame;

	// ===== Methods =====

	/// Requests the probe to update on the next frame.
	public void RequestUpdate()
	{
		mNeedsUpdate = true;
	}

	/// Gets the world-space axis-aligned bounding box of the influence volume.
	public BoundingBox GetWorldInfluenceBounds()
	{
		if (Node == null)
			return .(-mBoxExtents, mBoxExtents);

		let center = Node.WorldPosition + mBoxOffset;
		return .(center - mBoxExtents, center + mBoxExtents);
	}

	/// Returns the blend weight for a world-space point (1 = full influence, 0 = outside).
	public float GetInfluenceWeight(Vector3 worldPoint)
	{
		if (Node == null)
			return 0;

		let center = Node.WorldPosition + mBoxOffset;
		let localPoint = worldPoint - center;

		// Check if inside the box
		let absX = Math.Abs(localPoint.X);
		let absY = Math.Abs(localPoint.Y);
		let absZ = Math.Abs(localPoint.Z);

		if (absX > mBoxExtents.X || absY > mBoxExtents.Y || absZ > mBoxExtents.Z)
			return 0;

		if (mBlendDistance <= 0)
			return 1.0f;

		// Distance from edge (minimum across all axes)
		let dx = (mBoxExtents.X - absX) / mBlendDistance;
		let dy = (mBoxExtents.Y - absY) / mBlendDistance;
		let dz = (mBoxExtents.Z - absZ) / mBlendDistance;
		let minDist = Math.Min(dx, Math.Min(dy, dz));

		return Math.Clamp(minDist, 0, 1);
	}

	/// Creates the cubemap texture for rendering into.
	/// Called by the renderer before capture.
	public Result<void> CreateCubemap(IDevice device)
	{
		if (mCubemapTexture != null)
			return .Ok;

		let mipLevels = CalculateMipLevels(mResolution);
		var desc = TextureDescriptor.Cubemap(
			(uint32)mResolution,
			.RGBA8Unorm,
			.RenderTarget | .Sampled | .CopyDst,
			mipLevels
		);

		if (device.CreateTexture(&desc) case .Ok(let tex))
		{
			mCubemapTexture = tex;

			TextureViewDescriptor viewDesc = .()
			{
				Dimension = .TextureCube,
				Format = .RGBA8Unorm,
				MipLevelCount = mipLevels,
				ArrayLayerCount = 6
			};

			if (device.CreateTextureView(tex, &viewDesc) case .Ok(let view))
			{
				mCubemapView = view;
			}
			else
				return .Err;
		}
		else
			return .Err;

		return .Ok;
	}

	/// Marks the probe as updated for the given frame.
	public void MarkUpdated(uint64 frameNumber)
	{
		mNeedsUpdate = false;
		mLastUpdateFrame = frameNumber;

		// For baked mode, don't request further updates
		// For realtime, always keep requesting
		if (mMode == .Realtime)
			mNeedsUpdate = true;
	}

	/// Whether the probe should capture this frame.
	public bool ShouldCapture(uint64 frameNumber)
	{
		if (!mNeedsUpdate)
			return false;

		switch (mMode)
		{
		case .Baked:
			return mLastUpdateFrame == 0; // Only capture once
		case .Realtime:
			return true;
		case .OnDemand:
			return mNeedsUpdate;
		}
	}

	// ===== Capture Matrices =====

	/// Standard cubemap face directions (right-handed, +X, -X, +Y, -Y, +Z, -Z).
	private static readonly (Vector3 target, Vector3 up)[6] sCubeFaceDirections = .(
		(.(1, 0, 0), .(0, 1, 0)),    // +X
		(.(-1, 0, 0), .(0, 1, 0)),   // -X
		(.(0, 1, 0), .(0, 0, -1)),   // +Y
		(.(0, -1, 0), .(0, 0, 1)),   // -Y
		(.(0, 0, 1), .(0, 1, 0)),    // +Z
		(.(0, 0, -1), .(0, 1, 0))    // -Z
	);

	/// Gets the view matrix for capturing a specific cubemap face (0-5).
	public Matrix GetCaptureViewMatrix(int faceIndex)
	{
		let pos = Node != null ? Node.WorldPosition : Vector3.Zero;
		let dir = sCubeFaceDirections[faceIndex];
		return Matrix.CreateLookAt(pos, pos + dir.target, dir.up);
	}

	/// Gets the projection matrix for cubemap capture (90-degree FOV, square aspect).
	public Matrix GetCaptureProjectionMatrix()
	{
		return Matrix.CreatePerspectiveFieldOfView(
			Math.PI_f * 0.5f, // 90 degrees
			1.0f,             // Square aspect ratio
			mNearClip,
			mFarClip
		);
	}

	/// Creates per-face texture views for render-to-cubemap.
	/// Returns an array of 6 ITextureView objects, one per cubemap face.
	public Result<void> CreateFaceViews(IDevice device, out ITextureView[6] outViews)
	{
		outViews = default;
		if (mCubemapTexture == null)
			return .Err;

		for (int32 face = 0; face < 6; face++)
		{
			TextureViewDescriptor faceViewDesc = .()
			{
				Dimension = .Texture2D,
				Format = .RGBA8Unorm,
				BaseMipLevel = 0,
				MipLevelCount = 1,
				BaseArrayLayer = (uint32)face,
				ArrayLayerCount = 1
			};

			if (device.CreateTextureView(mCubemapTexture, &faceViewDesc) case .Ok(let faceView))
				outViews[face] = faceView;
			else
			{
				// Clean up any already-created views
				for (int32 j = 0; j < face; j++)
				{
					if (outViews[j] != null) delete outViews[j];
					outViews[j] = null;
				}
				return .Err;
			}
		}
		return .Ok;
	}

	// ===== Private =====

	private static uint32 CalculateMipLevels(int32 resolution)
	{
		uint32 mips = 1;
		int32 size = resolution;
		while (size > 1)
		{
			size >>= 1;
			mips++;
		}
		return mips;
	}
}
