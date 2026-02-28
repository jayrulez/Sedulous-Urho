using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// How the sprite is positioned and sized.
public enum SpriteDrawMode
{
	/// Positioned in world space, sized in world units.
	World,
	/// Positioned in screen space (pixels), camera-independent.
	Screen
}

/// 2D sprite rendering component.
///
/// Renders a textured quad with support for UV regions (sprite sheets),
/// color tinting, horizontal/vertical flip, and world or screen draw modes.
/// In world mode the quad is billboarded to face the camera.
///
[EngineComponent("Rendering")]
public class Sprite2D : Drawable
{
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private MaterialInstance mMaterial;
	private IBuffer[MAX_FRAMES] mVertexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private IBuffer[MAX_FRAMES] mIndexBuffers ~ { for (let b in _) if (b != null) delete b; };
	private uint8[] mVertexData ~ delete _;
	private uint8[] mIndexData ~ delete _;
	private bool mBuffersDirty = true;
	private bool[MAX_FRAMES] mBuffersAllocated;

	// Sprite properties
	private Vector2 mSize = .(1.0f, 1.0f);
	private Vector2 mPivot = .(0.5f, 0.5f); // Normalized (0..1)
	private Vector4 mUVRect = .(0, 0, 1, 1); // (uMin, vMin, uMax, vMax)
	private uint32 mColor = 0xFFFFFFFF;
	private bool mFlipX = false;
	private bool mFlipY = false;
	private SpriteDrawMode mDrawMode = .World;
	private int32 mLayer = 0;
	private Vector2 mScreenPosition = .Zero;

	// Vertex: Position(Vec3=12) + UV(Vec2=8) + Color(uint32=4) = 24 bytes
	private const int32 VERTEX_SIZE = 24;

	public this()
	{
		SetDrawableType(.Geometry);
	}

	// ===== Properties =====

	/// Size of the sprite (world units or pixels depending on DrawMode).
	public Vector2 Size
	{
		get => mSize;
		set { mSize = value; mBuffersDirty = true; UpdateLocalBounds(); }
	}

	/// Pivot point as normalized coordinates (0,0 = bottom-left, 0.5,0.5 = center).
	public Vector2 Pivot
	{
		get => mPivot;
		set { mPivot = value; mBuffersDirty = true; }
	}

	/// UV rectangle for sprite sheet regions: (uMin, vMin, uMax, vMax).
	public Vector4 UVRect
	{
		get => mUVRect;
		set { mUVRect = value; mBuffersDirty = true; }
	}

	/// Tint color (packed RGBA).
	public uint32 Color
	{
		get => mColor;
		set { mColor = value; mBuffersDirty = true; }
	}

	/// Flip the sprite horizontally.
	public bool FlipX
	{
		get => mFlipX;
		set { mFlipX = value; mBuffersDirty = true; }
	}

	/// Flip the sprite vertically.
	public bool FlipY
	{
		get => mFlipY;
		set { mFlipY = value; mBuffersDirty = true; }
	}

	/// Draw mode: World (billboarded) or Screen (overlay).
	public SpriteDrawMode DrawMode
	{
		get => mDrawMode;
		set => mDrawMode = value;
	}

	/// Rendering layer for draw order (higher draws on top).
	public int32 Layer
	{
		get => mLayer;
		set => mLayer = value;
	}

	/// Screen position in pixels (only used when DrawMode is Screen).
	public Vector2 ScreenPosition
	{
		get => mScreenPosition;
		set => mScreenPosition = value;
	}

	/// Material for the sprite.
	public MaterialInstance Material
	{
		get => mMaterial;
		set => mMaterial = value;
	}

	// ===== Batch Generation =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (Node == null)
			return;

		let cameraNode = frameInfo.Camera?.Node;
		if (cameraNode == null)
			return;

		let cameraPos = cameraNode.WorldPosition;

		if (mDrawMode == .World)
			BuildWorldGeometry(cameraNode);
		else
			BuildScreenGeometry(frameInfo);

		let distance = Vector3.Distance(Node.WorldPosition, cameraPos);
		SourceBatch batch = .()
		{
			WorldTransform = .Identity, // Vertices already in world/screen space
			Distance = distance,
			StartIndex = 0,
			IndexCount = 6,
			VertexBuffer = null, // Patched by UploadToGPU with per-frame buffer
			IndexBuffer = null,
			IndexBufferFormat = .UInt16,
			Material = mMaterial,
			Drawable = this
		};
		MutableBatches.Add(batch);
	}

	/// Uploads sprite geometry to the GPU.
	/// Uses per-frame buffers to avoid destroying buffers still in use by the GPU.
	public Result<void> UploadToGPU(IDevice device, int32 frameIndex)
	{
		let fi = frameIndex;
		let vertexDataSize = (uint64)(4 * VERTEX_SIZE);
		let indexDataSize = (uint64)(6 * 2); // UInt16

		if (!mBuffersAllocated[fi])
		{
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

			mBuffersAllocated[fi] = true;
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

	private void BuildWorldGeometry(Node cameraNode)
	{
		EnsureCPUBuffers();

		let worldPos = Node.WorldPosition;
		let right = cameraNode.WorldRight;
		let up = cameraNode.WorldUp;

		// Pivot offset
		let pivotOffX = -mPivot.X * mSize.X;
		let pivotOffY = -mPivot.Y * mSize.Y;

		// Quad corners relative to pivot
		Vector3[4] positions;
		positions[0] = worldPos + right * pivotOffX + up * pivotOffY;                          // BL
		positions[1] = worldPos + right * (pivotOffX + mSize.X) + up * pivotOffY;              // BR
		positions[2] = worldPos + right * (pivotOffX + mSize.X) + up * (pivotOffY + mSize.Y); // TR
		positions[3] = worldPos + right * pivotOffX + up * (pivotOffY + mSize.Y);              // TL

		WriteQuad(positions);
	}

	private void BuildScreenGeometry(FrameInfo frameInfo)
	{
		EnsureCPUBuffers();

		// Screen space: map pixel coords to NDC-like positions
		// The renderer will need to handle this with an ortho projection
		let x = mScreenPosition.X;
		let y = mScreenPosition.Y;
		let pivotOffX = -mPivot.X * mSize.X;
		let pivotOffY = -mPivot.Y * mSize.Y;

		Vector3[4] positions;
		positions[0] = .(x + pivotOffX, y + pivotOffY, 0);
		positions[1] = .(x + pivotOffX + mSize.X, y + pivotOffY, 0);
		positions[2] = .(x + pivotOffX + mSize.X, y + pivotOffY + mSize.Y, 0);
		positions[3] = .(x + pivotOffX, y + pivotOffY + mSize.Y, 0);

		WriteQuad(positions);
	}

	private void WriteQuad(Vector3[4] positions)
	{
		// UV coordinates with flip support
		float uMin = mFlipX ? mUVRect.Z : mUVRect.X;
		float uMax = mFlipX ? mUVRect.X : mUVRect.Z;
		float vMin = mFlipY ? mUVRect.W : mUVRect.Y;
		float vMax = mFlipY ? mUVRect.Y : mUVRect.W;

		Vector2[4] uvs;
		uvs[0] = .(uMin, vMax); // BL
		uvs[1] = .(uMax, vMax); // BR
		uvs[2] = .(uMax, vMin); // TR
		uvs[3] = .(uMin, vMin); // TL

		for (int32 v = 0; v < 4; v++)
		{
			let offset = v * VERTEX_SIZE;
			*(Vector3*)&mVertexData[offset] = positions[v];
			*(Vector2*)&mVertexData[offset + 12] = uvs[v];
			*(uint32*)&mVertexData[offset + 20] = mColor;
		}

		// Indices: two triangles
		uint16* indices = (uint16*)&mIndexData[0];
		indices[0] = 0;
		indices[1] = 1;
		indices[2] = 2;
		indices[3] = 0;
		indices[4] = 2;
		indices[5] = 3;
	}

	private void EnsureCPUBuffers()
	{
		let vertexDataSize = 4 * VERTEX_SIZE;
		let indexDataSize = 6 * 2;

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
	}

	private void UpdateLocalBounds()
	{
		// Use the larger of X/Y half-size for Z extent since the sprite
		// is billboarded and can face any direction relative to its node.
		let maxHalf = Math.Max(mSize.X, mSize.Y) * 0.5f;
		let half = Vector3(maxHalf, maxHalf, maxHalf);
		BoundingBox = .(-half, half);
	}

	protected override void OnRemoved()
	{
		base.OnRemoved();
	}
}
