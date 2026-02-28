using System;
using Sedulous.Foundation.Mathematics;

namespace Sedulous.Engine.Renderer;

/// Per-frame rendering context passed to drawables during batch collection.
public struct FrameInfo
{
	/// Current frame number.
	public uint64 FrameNumber;
	/// Time since last frame in seconds.
	public float TimeStep;
	/// Viewport dimensions in pixels.
	public int32 ViewportWidth;
	/// Viewport dimensions in pixels.
	public int32 ViewportHeight;
	/// The camera used for rendering.
	public Camera Camera;
}
