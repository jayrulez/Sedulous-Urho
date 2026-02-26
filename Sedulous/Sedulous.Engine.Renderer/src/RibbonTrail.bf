using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// How the trail width is distributed around the node position.
public enum TrailType
{
	/// Trail faces the camera (like a billboard strip).
	FaceCamera,
	/// Trail extends along a fixed local-space axis.
	Bone
}

/// A single trail segment recording position and state at a point in time.
struct TrailPoint
{
	public Vector3 Position;
	public Vector3 Forward;
	public float Width;
	public uint32 Color;
	public float Lifetime;
	public float TimeAlive;
}

/// Ribbon trail drawable that renders a smooth strip behind a moving object.
///
/// The trail records the node's position each frame and generates a
/// camera-facing (or bone-aligned) strip mesh connecting the points.
/// Old points fade out and are removed based on lifetime.
///
[EngineComponent("Rendering")]
public class RibbonTrail : Drawable
{
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private List<TrailPoint> mPoints = new .() ~ delete _;
	private IBuffer[MAX_FRAMES] mVertexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private IBuffer[MAX_FRAMES] mIndexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private uint8[] mVertexData ~ delete _;
	private uint8[] mIndexData ~ delete _;
	private int32[MAX_FRAMES] mLastVertexCounts;
	private MaterialInstance mMaterial;
	private Vector3 mPreviousPosition;
	private bool mFirstUpdate = true;

	// Trail parameters
	private TrailType mTrailType = .FaceCamera;
	private float mWidth = 1.0f;
	private float mLifetime = 1.0f;
	private float mMinVertexDistance = 0.1f;
	private int32 mMaxPoints = 100;
	private uint32 mStartColor = 0xFFFFFFFF;
	private uint32 mEndColor = 0x00FFFFFF;
	private float mEndWidth = 0.0f;
	private bool mEmitting = true;
	private float mUVPerUnit = 1.0f;

	// Vertex: Position(Vec3=12) + UV(Vec2=8) + Color(uint32=4) = 24 bytes
	private const int32 VERTEX_SIZE = 24;

	public this()
	{
		SetDrawableType(.Geometry);
	}

	// ===== Properties =====

	/// Trail type: FaceCamera or Bone.
	public TrailType TrailType
	{
		get => mTrailType;
		set => mTrailType = value;
	}

	/// Width of the trail at the emitting end.
	public float Width
	{
		get => mWidth;
		set => mWidth = Math.Max(value, 0.01f);
	}

	/// Width of the trail at the fading end (0 = shrink to nothing).
	public float EndWidth
	{
		get => mEndWidth;
		set => mEndWidth = Math.Max(value, 0.0f);
	}

	/// How long each trail point lives (seconds).
	public float Lifetime
	{
		get => mLifetime;
		set => mLifetime = Math.Max(value, 0.01f);
	}

	/// Minimum distance the node must move before a new point is added.
	public float MinVertexDistance
	{
		get => mMinVertexDistance;
		set => mMinVertexDistance = Math.Max(value, 0.001f);
	}

	/// Maximum number of trail points.
	public int32 MaxPoints
	{
		get => mMaxPoints;
		set => mMaxPoints = Math.Max(value, 2);
	}

	/// Color at the emitting end (packed RGBA).
	public uint32 StartColor
	{
		get => mStartColor;
		set => mStartColor = value;
	}

	/// Color at the fading end (packed RGBA).
	public uint32 EndColor
	{
		get => mEndColor;
		set => mEndColor = value;
	}

	/// Whether the trail is actively emitting new points.
	public bool Emitting
	{
		get => mEmitting;
		set => mEmitting = value;
	}

	/// UV tiling per world unit of trail length.
	public float UVPerUnit
	{
		get => mUVPerUnit;
		set => mUVPerUnit = Math.Max(value, 0.001f);
	}

	/// Material for the trail.
	public MaterialInstance Material
	{
		get => mMaterial;
		set => mMaterial = value;
	}

	/// Current number of trail points.
	public int32 PointCount => (int32)mPoints.Count;

	// ===== Trail Control =====

	/// Clears all trail points immediately.
	public void Clear()
	{
		mPoints.Clear();
		mFirstUpdate = true;
	}

	// ===== Batch Generation =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (Node == null)
			return;

		let deltaTime = frameInfo.TimeStep;
		let worldPos = Node.WorldPosition;

		// Age existing points and remove expired ones
		AgePoints(deltaTime);

		// Add new point if moved far enough
		if (mEmitting)
		{
			if (mFirstUpdate)
			{
				mPreviousPosition = worldPos;
				AddPoint(worldPos, Node.WorldDirection);
				mFirstUpdate = false;
			}
			else
			{
				let dist = Vector3.Distance(worldPos, mPreviousPosition);
				if (dist >= mMinVertexDistance)
				{
					AddPoint(worldPos, Node.WorldDirection);
					mPreviousPosition = worldPos;
				}
			}
		}

		if (mPoints.Count < 2)
			return;

		// Build geometry
		let cameraNode = frameInfo.Camera?.Node;
		if (cameraNode == null)
			return;

		let cameraPos = cameraNode.WorldPosition;
		BuildGeometry(cameraPos);

		// Update bounding box from trail points
		UpdateTrailBounds();

		// Submit batch
		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);
		let segmentCount = (int32)mPoints.Count - 1;
		SourceBatch batch = .()
		{
			WorldTransform = .Identity, // Vertices already in world space
			Distance = distance,
			StartIndex = 0,
			IndexCount = segmentCount * 6,
			VertexBuffer = null, // Patched by UploadToGPU with per-frame buffer
			IndexBuffer = null,
			IndexBufferFormat = .UInt16,
			Material = mMaterial,
			Drawable = this
		};
		MutableBatches.Add(batch);
	}

	/// Uploads trail geometry to the GPU.
	/// Uses per-frame buffers to avoid destroying buffers still in use by the GPU.
	public Result<void> UploadToGPU(IDevice device, int32 frameIndex)
	{
		if (mPoints.Count < 2)
			return .Ok;

		let fi = frameIndex;
		let vertexCount = (int32)mPoints.Count * 2;
		let segmentCount = (int32)mPoints.Count - 1;
		let vertexDataSize = (uint64)(vertexCount * VERTEX_SIZE);
		let indexDataSize = (uint64)(segmentCount * 6 * 2); // UInt16

		// Recreate this frame's buffers if vertex count changed
		if (mVertexBuffers[fi] == null || mLastVertexCounts[fi] != vertexCount)
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

			mLastVertexCounts[fi] = vertexCount;
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

		return .Ok;
	}

	// ===== Private =====

	private void AddPoint(Vector3 position, Vector3 forward)
	{
		// Enforce max count by removing oldest
		while (mPoints.Count >= mMaxPoints)
			mPoints.RemoveAt(0);

		TrailPoint pt = .()
		{
			Position = position,
			Forward = forward,
			Width = mWidth,
			Color = mStartColor,
			Lifetime = mLifetime,
			TimeAlive = 0
		};
		mPoints.Add(pt);
	}

	private void AgePoints(float deltaTime)
	{
		for (int i = mPoints.Count - 1; i >= 0; i--)
		{
			mPoints[i].TimeAlive += deltaTime;
			if (mPoints[i].TimeAlive >= mPoints[i].Lifetime)
			{
				mPoints.RemoveAt(i);
			}
		}
	}

	private void BuildGeometry(Vector3 cameraPos)
	{
		let pointCount = (int32)mPoints.Count;
		let vertexCount = pointCount * 2;
		let segmentCount = pointCount - 1;
		let vertexDataSize = vertexCount * VERTEX_SIZE;
		let indexDataSize = segmentCount * 6 * 2;

		// Resize CPU buffers
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

		// Accumulate UV distance
		float accumulatedDist = 0;

		for (int32 i = 0; i < pointCount; i++)
		{
			let pt = mPoints[i];
			let t = pt.Lifetime > 0 ? pt.TimeAlive / pt.Lifetime : 1.0f;

			// Interpolate width
			let width = Math.Lerp(mWidth, mEndWidth, t) * 0.5f;

			// Interpolate color
			let color = LerpColor(mStartColor, mEndColor, t);

			// Compute perpendicular direction for the strip
			Vector3 side;
			if (mTrailType == .FaceCamera)
			{
				// Camera-facing: side is perpendicular to both the trail direction and camera direction
				Vector3 trailDir;
				if (i < pointCount - 1)
					trailDir = Vector3.Normalize(mPoints[i + 1].Position - pt.Position);
				else if (i > 0)
					trailDir = Vector3.Normalize(pt.Position - mPoints[i - 1].Position);
				else
					trailDir = pt.Forward;

				let toCamera = Vector3.Normalize(cameraPos - pt.Position);
				side = Vector3.Normalize(Vector3.Cross(trailDir, toCamera));
			}
			else
			{
				// Bone mode: use a fixed up axis
				side = Vector3.Normalize(Vector3.Cross(pt.Forward, Vector3.UnitY));
				if (side.LengthSquared() < 0.001f)
					side = Vector3.Normalize(Vector3.Cross(pt.Forward, Vector3.UnitX));
			}

			// UV v coordinate based on accumulated distance
			if (i > 0)
				accumulatedDist += Vector3.Distance(mPoints[i].Position, mPoints[i - 1].Position);
			let u = accumulatedDist * mUVPerUnit;

			// Two vertices: left and right edge
			let leftPos = pt.Position - side * width;
			let rightPos = pt.Position + side * width;

			let baseOffset = i * 2 * VERTEX_SIZE;

			// Left vertex
			*(Vector3*)&mVertexData[baseOffset] = leftPos;
			*(Vector2*)&mVertexData[baseOffset + 12] = .(u, 0.0f);
			*(uint32*)&mVertexData[baseOffset + 20] = color;

			// Right vertex
			*(Vector3*)&mVertexData[baseOffset + VERTEX_SIZE] = rightPos;
			*(Vector2*)&mVertexData[baseOffset + VERTEX_SIZE + 12] = .(u, 1.0f);
			*(uint32*)&mVertexData[baseOffset + VERTEX_SIZE + 20] = color;
		}

		// Generate indices for the strip (two triangles per segment)
		for (int32 i = 0; i < segmentCount; i++)
		{
			let v0 = (uint16)(i * 2);
			let v1 = (uint16)(i * 2 + 1);
			let v2 = (uint16)(i * 2 + 2);
			let v3 = (uint16)(i * 2 + 3);

			let idxOffset = i * 6 * 2;
			uint16* indices = (uint16*)&mIndexData[idxOffset];
			indices[0] = v0;
			indices[1] = v1;
			indices[2] = v2;
			indices[3] = v2;
			indices[4] = v1;
			indices[5] = v3;
		}
	}

	private void UpdateTrailBounds()
	{
		if (mPoints.Count == 0)
			return;

		var min = Vector3(float.MaxValue);
		var max = Vector3(float.MinValue);
		for (let pt in mPoints)
		{
			let expand = Vector3(mWidth);
			min = Vector3.Min(min, pt.Position - expand);
			max = Vector3.Max(max, pt.Position + expand);
		}

		// Set as world bounding box directly (points are already world-space)
		BoundingBox = .(min, max);
	}

	private static uint32 LerpColor(uint32 a, uint32 b, float t)
	{
		let t1 = Math.Clamp(t, 0, 1);
		let ra = (float)(a & 0xFF);
		let ga = (float)((a >> 8) & 0xFF);
		let ba = (float)((a >> 16) & 0xFF);
		let aa = (float)((a >> 24) & 0xFF);

		let rb = (float)(b & 0xFF);
		let gb = (float)((b >> 8) & 0xFF);
		let bb = (float)((b >> 16) & 0xFF);
		let ab = (float)((b >> 24) & 0xFF);

		let r = (uint32)Math.Lerp(ra, rb, t1);
		let g = (uint32)Math.Lerp(ga, gb, t1);
		let bl = (uint32)Math.Lerp(ba, bb, t1);
		let al = (uint32)Math.Lerp(aa, ab, t1);

		return r | (g << 8) | (bl << 16) | (al << 24);
	}

	protected override void OnRemoved()
	{
		base.OnRemoved();
	}
}
