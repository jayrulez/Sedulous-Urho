using System;
using System.Collections;
using System.Diagnostics;
using Sedulous.Foundation.Core;
using Sedulous.Foundation.Logging.Abstractions;
using Sedulous.Shell;
using Sedulous.Shell.Input;
using Sedulous.RHI;
using Sedulous.Jobs;
using Sedulous.Resources;
using Sedulous.Profiler;

namespace Sedulous.Engine.Core;

/// Core engine class managing the main loop and subsystem lifecycle.
///
/// The Engine owns the Context and dispatches frame events.
/// Subsystems (Shell, Graphics, etc.) are registered by the Application
/// before the engine starts its frame loop.
///
/// Frame order:
///   1. ProcessInput (Shell.ProcessEvents + InputManager.Update)
///   2. FrameBegin event
///   3. FixedUpdate events (0..N times at fixed timestep)
///   4. Update event
///   5. PostUpdate event
///   6. RenderUpdate event
///   7. PostRenderUpdate event
///   8. FrameEnd event
///
public class Engine
{
	private Context mContext ~ delete _;
	private bool mInitialized = false;
	private bool mRunning = false;
	private bool mExiting = false;

	// Timing
	private Stopwatch mStopwatch = new .() ~ delete _;
	private float mDeltaTime;
	private float mTotalTime;
	private float mLastFrameTime;
	private float mFixedTimeStep = 1.0f / 60.0f;
	private float mFixedUpdateAccumulator = 0.0f;
	private int32 mMaxFixedStepsPerFrame = 8;
	private int32 mTargetFrameRate = 0;
	private float mTargetFrameTime = 0.0f;
	private uint64 mFrameNumber = 0;

	// Frame events
	private EventAccessor<FrameEventHandler> mOnFrameBegin = new .() ~ delete _;
	private EventAccessor<UpdateEventHandler> mOnFixedUpdate = new .() ~ delete _;
	private EventAccessor<UpdateEventHandler> mOnUpdate = new .() ~ delete _;
	private EventAccessor<FrameEventHandler> mOnPostUpdate = new .() ~ delete _;
	private EventAccessor<FrameEventHandler> mOnRenderUpdate = new .() ~ delete _;
	private EventAccessor<FrameEventHandler> mOnPostRenderUpdate = new .() ~ delete _;
	private EventAccessor<FrameEventHandler> mOnFrameEnd = new .() ~ delete _;
	private EventAccessor<ResizeEventHandler> mOnResize = new .() ~ delete _;

	// ===== Public Accessors =====

	/// The engine's central context (subsystem registry + component factory).
	public Context Context => mContext;

	/// Whether the engine has been initialized.
	public bool IsInitialized => mInitialized;

	/// Whether the engine is currently running the frame loop.
	public bool IsRunning => mRunning;

	/// Current frame's delta time in seconds.
	public float DeltaTime => mDeltaTime;

	/// Total elapsed time since engine start in seconds.
	public float TotalTime => mTotalTime;

	/// Current frame number (monotonically increasing).
	public uint64 FrameNumber => mFrameNumber;

	/// Gets or sets the fixed timestep in seconds.
	public float FixedTimeStep
	{
		get => mFixedTimeStep;
		set => mFixedTimeStep = Math.Max(value, 0.001f);
	}

	/// Gets or sets the target frame rate (0 = unlimited).
	public int32 TargetFrameRate
	{
		get => mTargetFrameRate;
		set
		{
			mTargetFrameRate = Math.Max(value, 0);
			mTargetFrameTime = (mTargetFrameRate > 0) ? (1.0f / mTargetFrameRate) : 0.0f;
		}
	}

	// ===== Frame Events =====

	/// Fired at the start of each frame.
	public EventAccessor<FrameEventHandler> OnFrameBegin => mOnFrameBegin;

	/// Fired at fixed timestep intervals (may fire 0..N times per frame).
	public EventAccessor<UpdateEventHandler> OnFixedUpdate => mOnFixedUpdate;

	/// Fired once per frame with the variable delta time.
	public EventAccessor<UpdateEventHandler> OnUpdate => mOnUpdate;

	/// Fired after the main update.
	public EventAccessor<FrameEventHandler> OnPostUpdate => mOnPostUpdate;

	/// Fired during the render preparation phase.
	public EventAccessor<FrameEventHandler> OnRenderUpdate => mOnRenderUpdate;

	/// Fired after render preparation.
	public EventAccessor<FrameEventHandler> OnPostRenderUpdate => mOnPostRenderUpdate;

	/// Fired at the end of each frame.
	public EventAccessor<FrameEventHandler> OnFrameEnd => mOnFrameEnd;

	/// Fired when the main window is resized.
	public EventAccessor<ResizeEventHandler> OnResize => mOnResize;

	// ===== Lifecycle =====

	public this()
	{
	}

	public ~this()
	{
	}

	/// Initializes the engine with the given parameters.
	/// Subsystems should be registered in the Context before calling this.
	public Result<void> Initialize(EngineParameters @params, ILogger logger = null)
	{
		if (mInitialized)
			return .Err;

		mContext = new Context(logger);

		// Apply timing parameters
		mFixedTimeStep = Math.Max(@params.FixedTimeStep, 0.001f);
		mMaxFixedStepsPerFrame = Math.Max(@params.MaxFixedStepsPerFrame, 1);
		TargetFrameRate = @params.TargetFrameRate;

		// Discover component types via reflection
		mContext.DiscoverComponents();

		mInitialized = true;
		mContext.Logger?.LogInformation("Engine initialized.");
		return .Ok;
	}

	/// Runs a single frame. Returns false if the engine should exit.
	public bool RunFrame()
	{
		if (!mInitialized || mExiting)
			return false;

		SProfiler.BeginFrame();

		float frameStartTime = (float)mStopwatch.Elapsed.TotalSeconds;

		// --- Input ---
		using (SProfiler.Begin("ProcessInput"))
			ProcessInput();

		// Check if shell requested exit
		let shell = mContext.GetSubsystem<IShell>();
		if (shell != null && !shell.IsRunning)
		{
			mExiting = true;
			SProfiler.EndFrame();
			return false;
		}

		// --- Timing ---
		float currentTime = (float)mStopwatch.Elapsed.TotalSeconds;
		mDeltaTime = currentTime - mLastFrameTime;
		mLastFrameTime = currentTime;
		mTotalTime = currentTime;
		mFrameNumber++;

		// --- Frame Begin ---
		using (SProfiler.Begin("FrameBegin"))
			mOnFrameBegin.[Friend]Invoke();

		// --- Fixed Update ---
		using (SProfiler.Begin("FixedUpdate"))
		{
			mFixedUpdateAccumulator += mDeltaTime;
			int32 fixedSteps = 0;
			while (mFixedUpdateAccumulator >= mFixedTimeStep && fixedSteps < mMaxFixedStepsPerFrame)
			{
				mOnFixedUpdate.[Friend]Invoke(mFixedTimeStep);
				mFixedUpdateAccumulator -= mFixedTimeStep;
				fixedSteps++;
			}
			// Clamp accumulator to prevent spiral of death
			if (mFixedUpdateAccumulator > mFixedTimeStep * 2)
				mFixedUpdateAccumulator = mFixedTimeStep * 2;
		}

		// --- Update ---
		using (SProfiler.Begin("Update"))
			mOnUpdate.[Friend]Invoke(mDeltaTime);

		// --- Post Update ---
		using (SProfiler.Begin("PostUpdate"))
			mOnPostUpdate.[Friend]Invoke();

		// --- Update Jobs ---
		using (SProfiler.Begin("JobSystem"))
		{
			let jobSystem = mContext.GetSubsystem<JobSystem>();
			if (jobSystem != null)
				jobSystem.Update();
		}

		// --- Update Resources ---
		using (SProfiler.Begin("ResourceSystem"))
		{
			let resourceSystem = mContext.GetSubsystem<ResourceSystem>();
			if (resourceSystem != null)
				resourceSystem.Update();
		}

		// --- Render Update ---
		using (SProfiler.Begin("RenderUpdate"))
			mOnRenderUpdate.[Friend]Invoke();

		// --- Post Render Update ---
		using (SProfiler.Begin("PostRenderUpdate"))
			mOnPostRenderUpdate.[Friend]Invoke();

		// --- Frame End ---
		using (SProfiler.Begin("FrameEnd"))
			mOnFrameEnd.[Friend]Invoke();

		// --- Frame Pacing ---
		if (mTargetFrameTime > 0)
		{
			float frameEndTime = (float)mStopwatch.Elapsed.TotalSeconds;
			float frameElapsed = frameEndTime - frameStartTime;
			float sleepTime = mTargetFrameTime - frameElapsed;
			if (sleepTime > 0.001f)
			{
				System.Threading.Thread.Sleep((int32)(sleepTime * 1000));
			}
		}

		SProfiler.EndFrame();
		return true;
	}

	/// Starts the engine's internal clock. Called before entering the frame loop.
	public void Start()
	{
		mStopwatch.Start();
		mRunning = true;
		mContext.Logger?.LogInformation("Engine started.");
	}

	/// Shuts down the engine and releases resources.
	public void Shutdown()
	{
		if (!mInitialized)
			return;

		mRunning = false;
		mStopwatch.Stop();
		mContext.Logger?.LogInformation("Engine shut down.");
		mInitialized = false;
	}

	/// Requests the engine to exit at the end of the current frame.
	public void Exit()
	{
		mExiting = true;
		let shell = mContext.GetSubsystem<IShell>();
		shell?.RequestExit();
	}

	// ===== Private =====

	private void ProcessInput()
	{
		let shell = mContext.GetSubsystem<IShell>();
		if (shell != null)
		{
			shell.ProcessEvents();
			shell.InputManager.Update();
		}
	}
}
