using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.RHI;

namespace Sedulous.Engine.Renderer;

/// A viewport defines what is rendered: a scene viewed through a camera
/// onto a render target (or the backbuffer).
///
public class Viewport
{
	private Scene mScene;
	private Camera mCamera;
	private ITextureView mRenderTarget;
	private IntRect mRect;
	private PostProcessStack mPostProcessStack;

	/// The scene to render.
	public Scene Scene
	{
		get => mScene;
		set => mScene = value;
	}

	/// The camera to view the scene through.
	public Camera Camera
	{
		get => mCamera;
		set => mCamera = value;
	}

	/// The render target. Null means render to the backbuffer/swapchain.
	public ITextureView RenderTarget
	{
		get => mRenderTarget;
		set => mRenderTarget = value;
	}

	/// Sub-rectangle of the render target to render to.
	/// Zero rect means use the full render target.
	public IntRect Rect
	{
		get => mRect;
		set => mRect = value;
	}

	/// Optional post-process effect stack. When set, the scene is rendered
	/// to an intermediate HDR texture and effects are applied as fullscreen passes.
	public PostProcessStack PostProcessStack
	{
		get => mPostProcessStack;
		set => mPostProcessStack = value;
	}

	public this() { }

	public this(Scene scene, Camera camera)
	{
		mScene = scene;
		mCamera = camera;
	}
}

/// Integer rectangle for viewport regions.
public struct IntRect
{
	public int32 X;
	public int32 Y;
	public int32 Width;
	public int32 Height;

	public this()
	{
		X = 0; Y = 0; Width = 0; Height = 0;
	}

	public this(int32 x, int32 y, int32 width, int32 height)
	{
		X = x; Y = y; Width = width; Height = height;
	}

	/// Whether this rect is zero-sized (meaning "use full target").
	public bool IsEmpty => Width <= 0 || Height <= 0;
}
