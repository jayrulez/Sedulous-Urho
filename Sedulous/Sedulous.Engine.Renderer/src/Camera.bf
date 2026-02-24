using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Renderer;

/// Projection mode for the camera.
public enum ProjectionMode
{
	Perspective,
	Orthographic
}

/// Camera component that defines how a scene is viewed.
///
/// The camera generates view and projection matrices from its node's world
/// transform and projection settings. It also computes a view frustum for
/// visibility culling.
///
[EngineComponent("Rendering")]
public class Camera : Component
{
	// Projection settings
	private ProjectionMode mProjectionMode = .Perspective;
	private float mFov = Math.PI_f / 3.0f; // 60 degrees
	private float mNearClip = 0.1f;
	private float mFarClip = 1000.0f;
	private float mAspectRatio = 16.0f / 9.0f;
	private float mOrthoSize = 10.0f;
	private float mZoom = 1.0f;
	private bool mAutoAspectRatio = true;

	// Viewport masking
	private uint32 mViewMask = 0xFFFFFFFF;

	// Cached matrices (lazily computed)
	private Matrix mViewMatrix = .Identity;
	private Matrix mProjectionMatrix = .Identity;
	private BoundingFrustum mFrustum = .(Matrix.Identity);
	private bool mViewDirty = true;
	private bool mProjectionDirty = true;
	private bool mFrustumDirty = true;

	// Flip Y for Vulkan
	private bool mFlipY = false;

	// ===== Projection Properties =====

	/// Projection mode (Perspective or Orthographic).
	public ProjectionMode Projection
	{
		get => mProjectionMode;
		set { mProjectionMode = value; mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Vertical field of view in radians (perspective mode).
	public float Fov
	{
		get => mFov;
		set { mFov = Math.Clamp(value, 0.01f, Math.PI_f - 0.01f); mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Vertical field of view in degrees (convenience).
	public float FovDegrees
	{
		get => mFov * (180.0f / Math.PI_f);
		set => Fov = value * (Math.PI_f / 180.0f);
	}

	/// Near clipping plane distance.
	public float NearClip
	{
		get => mNearClip;
		set { mNearClip = Math.Max(value, 0.001f); mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Far clipping plane distance.
	public float FarClip
	{
		get => mFarClip;
		set { mFarClip = Math.Max(value, mNearClip + 0.001f); mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Aspect ratio (width / height). Ignored if AutoAspectRatio is true.
	public float AspectRatio
	{
		get => mAspectRatio;
		set { mAspectRatio = Math.Max(value, 0.01f); mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Whether the aspect ratio is automatically derived from the viewport.
	public bool AutoAspectRatio
	{
		get => mAutoAspectRatio;
		set => mAutoAspectRatio = value;
	}

	/// Orthographic view size (vertical extent in world units).
	public float OrthoSize
	{
		get => mOrthoSize;
		set { mOrthoSize = Math.Max(value, 0.01f); mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Zoom factor. Higher values zoom in.
	public float Zoom
	{
		get => mZoom;
		set { mZoom = Math.Max(value, 0.01f); mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Whether to flip Y in the projection matrix (for Vulkan).
	public bool FlipY
	{
		get => mFlipY;
		set { mFlipY = value; mProjectionDirty = true; mFrustumDirty = true; }
	}

	/// Bitmask for filtering which drawables this camera sees.
	public uint32 ViewMask
	{
		get => mViewMask;
		set => mViewMask = value;
	}

	// ===== Computed Properties =====

	/// The view matrix (world-to-view transform), derived from the node's world transform.
	public Matrix ViewMatrix
	{
		get
		{
			if (mViewDirty)
				UpdateViewMatrix();
			return mViewMatrix;
		}
	}

	/// The projection matrix.
	public Matrix ProjectionMatrix
	{
		get
		{
			if (mProjectionDirty)
				UpdateProjectionMatrix();
			return mProjectionMatrix;
		}
	}

	/// The combined view-projection matrix.
	public Matrix ViewProjectionMatrix => Matrix.Multiply(ViewMatrix, ProjectionMatrix);

	/// The view frustum in world space (for culling).
	public BoundingFrustum Frustum
	{
		get
		{
			if (mFrustumDirty || mViewDirty || mProjectionDirty)
				UpdateFrustum();
			return mFrustum;
		}
	}

	// ===== Methods =====

	/// Updates the aspect ratio from viewport dimensions.
	/// Called by the renderer before culling if AutoAspectRatio is true.
	public void SetAspectRatioFromViewport(int32 width, int32 height)
	{
		if (width > 0 && height > 0)
			AspectRatio = (float)width / (float)height;
	}

	/// Computes a world-space ray from normalized screen coordinates (0..1).
	public Ray GetScreenRay(float x, float y)
	{
		let viewProj = ViewProjectionMatrix;
		Matrix invViewProj = .Identity;
		if (!Matrix.TryInvert(viewProj, out invViewProj))
			return Ray(.Zero, .Forward);

		// Convert screen coords to NDC (-1..1)
		float ndcX = x * 2.0f - 1.0f;
		float ndcY = (1.0f - y) * 2.0f - 1.0f; // Flip Y

		// Near point and far point in NDC
		let nearPoint = Vector3.Transform(Vector3(ndcX, ndcY, 0.0f), invViewProj);
		let farPoint = Vector3.Transform(Vector3(ndcX, ndcY, 1.0f), invViewProj);

		let direction = Vector3.Normalize(farPoint - nearPoint);
		return Ray(nearPoint, direction);
	}

	// ===== Lifecycle =====

	protected override void OnTransformChanged()
	{
		mViewDirty = true;
		mFrustumDirty = true;
	}

	// ===== Private =====

	private void UpdateViewMatrix()
	{
		if (Node != null)
		{
			let worldTransform = Node.WorldTransform;
			// View matrix is the inverse of the camera's world transform
			if (!Matrix.TryInvert(worldTransform, out mViewMatrix))
				mViewMatrix = .Identity;
		}
		else
		{
			mViewMatrix = .Identity;
		}
		mViewDirty = false;
	}

	private void UpdateProjectionMatrix()
	{
		switch (mProjectionMode)
		{
		case .Perspective:
			Matrix.CreatePerspectiveFieldOfView(
				mFov / mZoom, mAspectRatio, mNearClip, mFarClip, out mProjectionMatrix);
		case .Orthographic:
			let halfHeight = mOrthoSize * 0.5f / mZoom;
			let halfWidth = halfHeight * mAspectRatio;
			Matrix.CreateOrthographicOffCenter(
				-halfWidth, halfWidth, -halfHeight, halfHeight, mNearClip, mFarClip, out mProjectionMatrix);
		}

		// Flip Y for Vulkan NDC (Y points down)
		if (mFlipY)
			mProjectionMatrix.M22 = -mProjectionMatrix.M22;

		mProjectionDirty = false;
	}

	private void UpdateFrustum()
	{
		// Ensure matrices are up to date
		if (mViewDirty) UpdateViewMatrix();
		if (mProjectionDirty) UpdateProjectionMatrix();

		mFrustum = BoundingFrustum(ViewProjectionMatrix);
		mFrustumDirty = false;
	}
}
