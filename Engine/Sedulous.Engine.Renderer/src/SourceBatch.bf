using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.RHI;
using Sedulous.Geometry;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// A single draw call produced by a Drawable.
///
/// Represents one renderable unit: a piece of geometry with a material,
/// positioned in the world. The renderer collects these from drawables
/// and sorts/batches them for efficient GPU submission.
///
public struct SourceBatch
{
	/// World transform matrix for this batch.
	public Matrix WorldTransform;
	/// Distance from the camera (for sorting and LOD).
	public float Distance;
	/// Geometry sub-mesh start index.
	public int32 StartIndex;
	/// Number of indices to draw (indexed path).
	public int32 IndexCount;
	/// Number of vertices to draw (non-indexed path, used when IndexBuffer is null).
	public int32 VertexCount;
	/// The GPU vertex buffer.
	public IBuffer VertexBuffer;
	/// The GPU index buffer (null for non-indexed draws).
	public IBuffer IndexBuffer;
	/// Index format (UInt16 or UInt32).
	public IndexFormat IndexBufferFormat;
	/// Material instance for this batch (determines shader, pipeline state, and bind group).
	public MaterialInstance Material;
	/// The drawable that produced this batch.
	public Drawable Drawable;
	/// Optional GPU buffer with bone/skinning matrices (for AnimatedModel).
	/// When non-null, the renderer should bind this for the skinned shader.
	public IBuffer BoneMatrixBuffer;
}
