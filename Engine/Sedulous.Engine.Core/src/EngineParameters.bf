using System;
using Sedulous.RHI;

namespace Sedulous.Engine.Core;

/// Configuration parameters for engine initialization.
/// Set these in Application.Setup() before the engine initializes.
public struct EngineParameters
{
	/// Window title.
	public String WindowTitle = "Sedulous Engine";

	/// Window width in pixels.
	public int32 WindowWidth = 1280;

	/// Window height in pixels.
	public int32 WindowHeight = 720;

	/// Whether the window is resizable.
	public bool WindowResizable = true;

	/// Whether to start in fullscreen mode.
	public bool Fullscreen = false;

	/// Whether to enable GPU validation layers (debug builds).
	public bool EnableValidation = true;

	/// Swap chain pixel format.
	public TextureFormat SwapChainFormat = .BGRA8UnormSrgb;

	/// Presentation mode (VSync control).
	public PresentMode PresentMode = .Mailbox;

	/// Target frame rate (0 = unlimited).
	public int32 TargetFrameRate = 0;

	/// Fixed update timestep in seconds.
	public float FixedTimeStep = 1.0f / 60.0f;

	/// Maximum fixed update steps per frame to prevent spiral of death.
	public int32 MaxFixedStepsPerFrame = 8;
}
