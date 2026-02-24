using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.Materials;
using Sedulous.Shaders;

namespace Sedulous.Engine.Renderer;

/// Vertex format for debug lines: position + packed color.
[CRepr]
public struct DebugVertex
{
	public Vector3 Position;
	public Color Color;

	public this(Vector3 position, Color color)
	{
		Position = position;
		Color = color;
	}
}

/// Debug rendering component for wireframe visualization.
///
/// Provides methods to add debug geometry (lines, boxes, spheres, frustums)
/// that is rendered as colored lines each frame. All debug geometry is
/// cleared at the start of each frame and must be re-added.
///
/// Supports both depth-tested and non-depth-tested (overlay) rendering.
///
[EngineComponent("Rendering")]
public class DebugRenderer : Component
{
	// Line vertex data (rebuilt each frame)
	private List<DebugVertex> mDepthLines = new .() ~ delete _;
	private List<DebugVertex> mNoDepthLines = new .() ~ delete _;

	// GPU buffers (owned, resized as needed)
	private IBuffer mDepthBuffer ~ { if (_ != null) delete _; };
	private IBuffer mNoDepthBuffer ~ { if (_ != null) delete _; };
	private int mDepthBufferCapacity = 0;
	private int mNoDepthBufferCapacity = 0;

	// Pipelines (cached)
	private IRenderPipeline mDepthPipeline;
	private IRenderPipeline mNoDepthPipeline;

	// ===== Adding Geometry =====

	/// Adds a line segment.
	public void AddLine(Vector3 start, Vector3 end, Color color, bool depthTest = true)
	{
		let list = depthTest ? mDepthLines : mNoDepthLines;
		list.Add(.(start, color));
		list.Add(.(end, color));
	}

	/// Adds a bounding box in world space.
	public void AddBoundingBox(BoundingBox @box, Color color, bool depthTest = true)
	{
		let min = @box.Min;
		let max = @box.Max;

		// 12 edges of a box
		// Bottom face
		AddLine(.(min.X, min.Y, min.Z), .(max.X, min.Y, min.Z), color, depthTest);
		AddLine(.(max.X, min.Y, min.Z), .(max.X, min.Y, max.Z), color, depthTest);
		AddLine(.(max.X, min.Y, max.Z), .(min.X, min.Y, max.Z), color, depthTest);
		AddLine(.(min.X, min.Y, max.Z), .(min.X, min.Y, min.Z), color, depthTest);
		// Top face
		AddLine(.(min.X, max.Y, min.Z), .(max.X, max.Y, min.Z), color, depthTest);
		AddLine(.(max.X, max.Y, min.Z), .(max.X, max.Y, max.Z), color, depthTest);
		AddLine(.(max.X, max.Y, max.Z), .(min.X, max.Y, max.Z), color, depthTest);
		AddLine(.(min.X, max.Y, max.Z), .(min.X, max.Y, min.Z), color, depthTest);
		// Vertical edges
		AddLine(.(min.X, min.Y, min.Z), .(min.X, max.Y, min.Z), color, depthTest);
		AddLine(.(max.X, min.Y, min.Z), .(max.X, max.Y, min.Z), color, depthTest);
		AddLine(.(max.X, min.Y, max.Z), .(max.X, max.Y, max.Z), color, depthTest);
		AddLine(.(min.X, min.Y, max.Z), .(min.X, max.Y, max.Z), color, depthTest);
	}

	/// Adds a bounding box with a transform.
	public void AddBoundingBox(BoundingBox @box, Matrix transform, Color color, bool depthTest = true)
	{
		let min = @box.Min;
		let max = @box.Max;

		// 8 corners
		Vector3[8] corners = .(
			Vector3.Transform(.(min.X, min.Y, min.Z), transform),
			Vector3.Transform(.(max.X, min.Y, min.Z), transform),
			Vector3.Transform(.(max.X, min.Y, max.Z), transform),
			Vector3.Transform(.(min.X, min.Y, max.Z), transform),
			Vector3.Transform(.(min.X, max.Y, min.Z), transform),
			Vector3.Transform(.(max.X, max.Y, min.Z), transform),
			Vector3.Transform(.(max.X, max.Y, max.Z), transform),
			Vector3.Transform(.(min.X, max.Y, max.Z), transform)
		);

		// Bottom face
		AddLine(corners[0], corners[1], color, depthTest);
		AddLine(corners[1], corners[2], color, depthTest);
		AddLine(corners[2], corners[3], color, depthTest);
		AddLine(corners[3], corners[0], color, depthTest);
		// Top face
		AddLine(corners[4], corners[5], color, depthTest);
		AddLine(corners[5], corners[6], color, depthTest);
		AddLine(corners[6], corners[7], color, depthTest);
		AddLine(corners[7], corners[4], color, depthTest);
		// Vertical edges
		AddLine(corners[0], corners[4], color, depthTest);
		AddLine(corners[1], corners[5], color, depthTest);
		AddLine(corners[2], corners[6], color, depthTest);
		AddLine(corners[3], corners[7], color, depthTest);
	}

	/// Adds a sphere approximation using circles on 3 axes.
	public void AddSphere(Vector3 center, float radius, Color color, bool depthTest = true, int segments = 24)
	{
		float angleStep = Math.PI_f * 2.0f / (float)segments;

		// XY circle
		for (int i = 0; i < segments; i++)
		{
			float a0 = angleStep * (float)i;
			float a1 = angleStep * (float)(i + 1);
			AddLine(
				center + Vector3(Math.Cos(a0) * radius, Math.Sin(a0) * radius, 0),
				center + Vector3(Math.Cos(a1) * radius, Math.Sin(a1) * radius, 0),
				color, depthTest);
		}

		// XZ circle
		for (int i = 0; i < segments; i++)
		{
			float a0 = angleStep * (float)i;
			float a1 = angleStep * (float)(i + 1);
			AddLine(
				center + Vector3(Math.Cos(a0) * radius, 0, Math.Sin(a0) * radius),
				center + Vector3(Math.Cos(a1) * radius, 0, Math.Sin(a1) * radius),
				color, depthTest);
		}

		// YZ circle
		for (int i = 0; i < segments; i++)
		{
			float a0 = angleStep * (float)i;
			float a1 = angleStep * (float)(i + 1);
			AddLine(
				center + Vector3(0, Math.Cos(a0) * radius, Math.Sin(a0) * radius),
				center + Vector3(0, Math.Cos(a1) * radius, Math.Sin(a1) * radius),
				color, depthTest);
		}
	}

	/// Adds a frustum visualization.
	public void AddFrustum(BoundingFrustum frustum, Color color, bool depthTest = true)
	{
		Vector3[BoundingFrustum.CornerCount] corners = .();
		frustum.GetCorners(ref corners);

		// Near plane
		AddLine(corners[0], corners[1], color, depthTest);
		AddLine(corners[1], corners[2], color, depthTest);
		AddLine(corners[2], corners[3], color, depthTest);
		AddLine(corners[3], corners[0], color, depthTest);
		// Far plane
		AddLine(corners[4], corners[5], color, depthTest);
		AddLine(corners[5], corners[6], color, depthTest);
		AddLine(corners[6], corners[7], color, depthTest);
		AddLine(corners[7], corners[4], color, depthTest);
		// Connecting edges
		AddLine(corners[0], corners[4], color, depthTest);
		AddLine(corners[1], corners[5], color, depthTest);
		AddLine(corners[2], corners[6], color, depthTest);
		AddLine(corners[3], corners[7], color, depthTest);
	}

	/// Adds a cross/axis marker at a position.
	public void AddCross(Vector3 center, float size, Color color, bool depthTest = true)
	{
		AddLine(center - Vector3(size, 0, 0), center + Vector3(size, 0, 0), color, depthTest);
		AddLine(center - Vector3(0, size, 0), center + Vector3(0, size, 0), color, depthTest);
		AddLine(center - Vector3(0, 0, size), center + Vector3(0, 0, size), color, depthTest);
	}

	/// Number of depth-tested line vertices this frame.
	public int DepthLineCount => mDepthLines.Count / 2;

	/// Number of overlay (no depth) line vertices this frame.
	public int NoDepthLineCount => mNoDepthLines.Count / 2;

	/// Whether there is any debug geometry to render.
	public bool HasContent => mDepthLines.Count > 0 || mNoDepthLines.Count > 0;

	// ===== Frame Lifecycle =====

	/// Clears all debug geometry for the new frame.
	public void BeginFrame()
	{
		mDepthLines.Clear();
		mNoDepthLines.Clear();
	}

	/// Uploads debug line data to GPU buffers.
	public void UpdateBuffers(IDevice device)
	{
		UploadLines(device, mDepthLines, ref mDepthBuffer, ref mDepthBufferCapacity);
		UploadLines(device, mNoDepthLines, ref mNoDepthBuffer, ref mNoDepthBufferCapacity);
	}

	/// Renders depth-tested debug lines.
	public void RenderDepthLines(IRenderPassEncoder encoder)
	{
		if (mDepthLines.Count == 0 || mDepthBuffer == null)
			return;

		if (mDepthPipeline != null)
			encoder.SetPipeline(mDepthPipeline);

		encoder.SetVertexBuffer(0, mDepthBuffer);
		encoder.Draw((uint32)mDepthLines.Count);
	}

	/// Renders overlay (no depth test) debug lines.
	public void RenderNoDepthLines(IRenderPassEncoder encoder)
	{
		if (mNoDepthLines.Count == 0 || mNoDepthBuffer == null)
			return;

		if (mNoDepthPipeline != null)
			encoder.SetPipeline(mNoDepthPipeline);

		encoder.SetVertexBuffer(0, mNoDepthBuffer);
		encoder.Draw((uint32)mNoDepthLines.Count);
	}

	/// Sets the cached pipelines for debug rendering.
	/// Call this once after pipeline creation.
	public void SetPipelines(IRenderPipeline depthPipeline, IRenderPipeline noDepthPipeline)
	{
		mDepthPipeline = depthPipeline;
		mNoDepthPipeline = noDepthPipeline;
	}

	// ===== Vertex Layout =====

	/// Returns the vertex buffer layout for debug vertices (position + color).
	public static VertexBufferLayout GetVertexLayout()
	{
		// Position: Float3 at offset 0, location 0
		// Color: UByte4Normalized at offset 12, location 1
		VertexAttribute[2] attributes = .(
			.(VertexFormat.Float3, 0, 0),
			.(VertexFormat.UByte4Normalized, 12, 1)
		);
		return VertexBufferLayout(16, attributes);
	}

	// ===== Private =====

	private static void UploadLines(IDevice device, List<DebugVertex> lines, ref IBuffer buffer, ref int capacity)
	{
		if (lines.Count == 0)
			return;

		let requiredSize = (uint64)(lines.Count * sizeof(DebugVertex));

		// Grow buffer if needed
		if (buffer == null || lines.Count > capacity)
		{
			if (buffer != null)
				delete buffer;

			let newCapacity = Math.Max(lines.Count, 1024);
			let bufferSize = (uint64)(newCapacity * sizeof(DebugVertex));
			BufferDescriptor desc = .(bufferSize, .Vertex | .CopyDst);
			if (device.CreateBuffer(&desc) case .Ok(let newBuffer))
			{
				buffer = newBuffer;
				capacity = newCapacity;
			}
			else
				return;
		}

		// Upload vertex data
		device.Queue.WriteBuffer(buffer, 0, Span<uint8>((uint8*)lines.Ptr, (int)requiredSize));
	}
}
