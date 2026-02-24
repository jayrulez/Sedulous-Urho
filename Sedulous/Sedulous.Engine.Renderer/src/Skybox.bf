using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// Skybox component that renders a cubemap environment background.
///
/// The skybox renders as a unit cube centered on the camera, drawn before
/// other geometry with depth write disabled. It uses a cubemap texture
/// view for environment mapping.
///
/// Attach to any node in the scene — the node's position is ignored
/// since the skybox always follows the camera.
///
[EngineComponent("Rendering")]
public class Skybox : Drawable
{
	private ITextureView mCubemapView;
	private IBuffer mVertexBuffer ~ { if (_ != null) delete _; };
	private IBuffer mIndexBuffer ~ { if (_ != null) delete _; };
	private IBindGroup mBindGroup ~ { if (_ != null) delete _; };
	private bool mBuffersCreated = false;

	public this()
	{
		SetDrawableType(.Geometry);
		// Skybox has infinite bounds so it's always visible
		BoundingBox = .(Vector3(-1e10f), Vector3(1e10f));
	}

	// ===== Properties =====

	/// The cubemap texture view for the skybox.
	public ITextureView CubemapView
	{
		get => mCubemapView;
		set
		{
			if (mCubemapView != value)
			{
				mCubemapView = value;
				// Invalidate bind group when cubemap changes
				if (mBindGroup != null)
				{
					delete mBindGroup;
					mBindGroup = null;
				}
			}
		}
	}

	/// The GPU vertex buffer for the skybox cube.
	public IBuffer VertexBuffer => mVertexBuffer;

	/// The GPU index buffer for the skybox cube.
	public IBuffer IndexBuffer => mIndexBuffer;

	/// The bind group for skybox rendering (cubemap + sampler).
	public IBindGroup BindGroup => mBindGroup;

	/// Ensures the bind group is created for rendering.
	/// Called by the Renderer before drawing.
	public void EnsureBindGroup(IDevice device, IBindGroupLayout layout, ISampler sampler)
	{
		if (mBindGroup != null || mCubemapView == null || layout == null || sampler == null)
			return;

		BindGroupEntry[2] entries = .(
			.Texture(0, mCubemapView, .ShaderReadOnly),
			.Sampler(0, sampler)
		);
		var bgDesc = BindGroupDescriptor(layout, entries);
		if (device.CreateBindGroup(&bgDesc) case .Ok(let bg))
			mBindGroup = bg;
	}

	// ===== GPU Resources =====

	/// Creates the skybox unit cube mesh on the GPU.
	public Result<void> CreateBuffers(IDevice device)
	{
		if (mBuffersCreated)
			return .Ok;

		// Unit cube vertices (positions only, 8 corners)
		float[24] vertices = .(
			-1, -1, -1,
			 1, -1, -1,
			 1,  1, -1,
			-1,  1, -1,
			-1, -1,  1,
			 1, -1,  1,
			 1,  1,  1,
			-1,  1,  1
		);

		// 12 triangles (36 indices), winding for inside-facing (camera is inside the cube)
		uint16[36] indices = .(
			// Front face (looking from inside)
			0, 2, 1, 0, 3, 2,
			// Back face
			4, 5, 6, 4, 6, 7,
			// Left face
			0, 4, 7, 0, 7, 3,
			// Right face
			1, 2, 6, 1, 6, 5,
			// Top face
			3, 7, 6, 3, 6, 2,
			// Bottom face
			0, 1, 5, 0, 5, 4
		);

		// Create vertex buffer
		let vbSize = (uint64)(vertices.Count * sizeof(float));
		BufferDescriptor vbDesc = .(vbSize, .Vertex | .CopyDst);
		if (device.CreateBuffer(&vbDesc) case .Ok(let vb))
		{
			mVertexBuffer = vb;
			device.Queue.WriteBuffer(vb, 0, Span<uint8>((uint8*)&vertices, (int)vbSize));
		}
		else
			return .Err;

		// Create index buffer
		let ibSize = (uint64)(indices.Count * sizeof(uint16));
		BufferDescriptor ibDesc = .(ibSize, .Index | .CopyDst);
		if (device.CreateBuffer(&ibDesc) case .Ok(let ib))
		{
			mIndexBuffer = ib;
			device.Queue.WriteBuffer(ib, 0, Span<uint8>((uint8*)&indices, (int)ibSize));
		}
		else
			return .Err;

		mBuffersCreated = true;
		return .Ok;
	}

	// ===== Batch Generation =====

	/// Generates a single batch for the skybox cube.
	public override void UpdateBatches(FrameInfo frameInfo)
	{
		MutableBatches.Clear();

		if (!mBuffersCreated || mCubemapView == null)
			return;

		// Skybox uses identity transform centered on camera
		Matrix worldTransform = .Identity;
		if (frameInfo.Camera != null && frameInfo.Camera.Node != null)
		{
			let camPos = frameInfo.Camera.Node.WorldPosition;
			worldTransform = Matrix.CreateTranslation(camPos);
		}

		SourceBatch batch = .()
		{
			WorldTransform = worldTransform,
			Distance = float.MaxValue, // Always draw last in opaque pass (or first with reverse depth)
			StartIndex = 0,
			IndexCount = 36,
			VertexBuffer = mVertexBuffer,
			IndexBuffer = mIndexBuffer,
			IndexBufferFormat = .UInt16,
			Material = null, // Skybox uses a dedicated pipeline, not a material
			Drawable = this
		};
		MutableBatches.Add(batch);
	}
}
