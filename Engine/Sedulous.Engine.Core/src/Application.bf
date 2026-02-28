using System;
using Sedulous.Foundation.Logging.Abstractions;

namespace Sedulous.Engine.Core;

/// Base class for engine applications.
///
/// Provides an Urho-style lifecycle:
///   1. Setup()    — Configure engine parameters before initialization
///   2. Start()    — Called after engine init, create your initial scene here
///   3. Stop()     — Called after the main loop ends, cleanup here
///
/// Usage:
///   class MyGame : Application
///   {
///       protected override void Setup() { Parameters.WindowTitle = "My Game"; }
///       protected override void Start() { /* create scene */ }
///       protected override void Stop()  { /* cleanup */ }
///   }
///
///   static void Main()
///   {
///       let app = scope MyGame();
///       app.Run();
///   }
///
public abstract class Application
{
	private Engine mEngine = new .() ~ delete _;
	private EngineParameters mParameters = .();
	private int32 mExitCode = 0;
	private ILogger mLogger;

	/// Engine parameters. Modify these in Setup() before the engine initializes.
	public ref EngineParameters Parameters => ref mParameters;

	/// The engine instance.
	public Engine Engine => mEngine;

	/// The engine context.
	public Context Context => mEngine.Context;

	/// Gets or sets the logger used by the engine.
	public ILogger Logger
	{
		get => mLogger;
		set => mLogger = value;
	}

	/// Runs the application: Setup → Initialize → Start → loop → Stop → Shutdown.
	/// Returns the exit code (0 = success).
	public int32 Run()
	{
		// --- Setup Phase ---
		// Let the derived class configure parameters
		Setup();

		// --- Initialize Phase ---
		// Create platform subsystems
		if (!InitializeSubsystems())
		{
			mLogger?.LogCritical("Failed to initialize subsystems.");
			ShutdownSubsystems();
			return 1;
		}

		// Initialize the engine
		if (mEngine.Initialize(mParameters, mLogger) case .Err)
		{
			mLogger?.LogCritical("Failed to initialize engine.");
			ShutdownSubsystems();
			return 1;
		}

		// Register subsystems in context
		RegisterSubsystems();

		// --- Start Phase ---
		mEngine.Start();
		Start();

		// --- Main Loop ---
		while (mEngine.RunFrame())
		{
		}

		// --- Stop Phase ---
		Stop();
		mEngine.Shutdown();
		ShutdownSubsystems();

		return mExitCode;
	}

	/// Requests the application to exit.
	public void Exit(int32 exitCode = 0)
	{
		mExitCode = exitCode;
		mEngine.Exit();
	}

	// ===== Virtual Lifecycle Hooks =====

	/// Called before engine initialization.
	/// Override to configure EngineParameters (window title, size, etc.).
	protected virtual void Setup()
	{
	}

	/// Called after engine initialization.
	/// Override to create the initial scene, load resources, and set up gameplay.
	protected virtual void Start()
	{
	}

	/// Called after the main loop ends.
	/// Override to perform cleanup.
	protected virtual void Stop()
	{
	}

	/// Called to create and initialize platform subsystems (Shell, Graphics, etc.).
	/// Override to provide custom subsystem implementations.
	/// Return true on success, false on failure.
	protected abstract bool InitializeSubsystems();

	/// Called to register subsystems with the engine Context.
	/// Override to register any subsystems the engine should know about.
	protected abstract void RegisterSubsystems();

	/// Called to shut down platform subsystems in reverse order.
	/// Override to clean up subsystems created in InitializeSubsystems().
	protected abstract void ShutdownSubsystems();
}
