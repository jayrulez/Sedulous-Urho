using System;
using System.Collections;
using System.IO;
using Sedulous.Foundation.Logging.Abstractions;
using Sedulous.Foundation.Logging.Console;
using Sedulous.Engine.Core;
using Sedulous.Shell;
using Sedulous.Shell.SDL3;
using Sedulous.Shell.Input;
using Sedulous.RHI;
using Sedulous.RHI.Vulkan;
using Sedulous.Jobs;
using Sedulous.Resources;

namespace Sedulous.Engine.App;

/// Concrete Application that sets up SDL3 for windowing/input and Vulkan for graphics.
/// Game applications should extend this class.
///
/// Usage:
///   class MyGame : SedulousApp
///   {
///       protected override void Setup() { Parameters.WindowTitle = "My Game"; }
///       protected override void Start() { /* create scene */ }
///   }
///
public class SedulousApp : Application
{
	// Platform subsystems (owned)
	private SDL3Shell mShell;
	private IBackend mBackend;
	private IDevice mDevice;
	private ISurface mSurface;
	private ISwapChain mSwapChain;
	private IWindow mWindow;
	private JobSystem mJobSystem;
	private ResourceSystem mResourceSystem;
	private ConsoleLogger mDefaultLogger;

	// Asset directory (discovered at startup)
	private String mAssetDirectory = new .() ~ delete _;

	// Per-frame command buffers
	private const int MAX_FRAMES_IN_FLIGHT = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private ICommandBuffer[MAX_FRAMES_IN_FLIGHT] mCommandBuffers;

	/// The primary window.
	public IWindow Window => mWindow;

	/// The GPU device.
	public IDevice Device => mDevice;

	/// The swap chain.
	public ISwapChain SwapChain => mSwapChain;

	/// The shell (windowing/input).
	public IShell Shell => mShell;

	/// The discovered Assets directory (absolute path).
	public StringView AssetDirectory => mAssetDirectory;

	/// Builds an absolute path by combining the asset directory with a relative path.
	public void GetAssetPath(StringView relativePath, String outPath)
	{
		outPath.Clear();
		Path.InternalCombine(outPath, mAssetDirectory, relativePath);
	}

	protected override bool InitializeSubsystems()
	{
		// Create default logger if none provided
		if (Logger == null)
		{
			mDefaultLogger = new ConsoleLogger(.Information, "Engine");
			Logger = mDefaultLogger;
		}

		Logger.LogInformation("Initializing subsystems...");

		// Discover assets directory
		DiscoverAssetDirectory();
		Logger.LogInformation("Asset directory: {}", mAssetDirectory);

		// --- Shell (SDL3) ---
		mShell = new SDL3Shell();
		if (mShell.Initialize() case .Err)
		{
			Logger.LogCritical("Failed to initialize SDL3 shell.");
			return false;
		}

		// Create main window
		String title = scope .(Parameters.WindowTitle);
		let windowSettings = WindowSettings()
		{
			Title = title,
			Width = Parameters.WindowWidth,
			Height = Parameters.WindowHeight,
			Resizable = Parameters.WindowResizable,
			Bordered = true,
			Fullscreen = Parameters.Fullscreen
		};

		if (mShell.WindowManager.CreateWindow(windowSettings) not case .Ok(let window))
		{
			Logger.LogCritical("Failed to create window.");
			return false;
		}
		mWindow = window;
		Logger.LogInformation("Window created: {}x{}", window.Width, window.Height);

		// --- Graphics (Vulkan) ---
		mBackend = new VulkanBackend(Parameters.EnableValidation);
		if (!mBackend.IsInitialized)
		{
			Logger.LogCritical("Failed to initialize Vulkan backend.");
			return false;
		}

		// Create surface from window
		if (mBackend.CreateSurface(mWindow.NativeHandle) not case .Ok(let surface))
		{
			Logger.LogCritical("Failed to create Vulkan surface.");
			return false;
		}
		mSurface = surface;

		// Select GPU adapter
		List<IAdapter> adapters = scope .();
		mBackend.EnumerateAdapters(adapters);
		if (adapters.Count == 0)
		{
			Logger.LogCritical("No GPU adapters found.");
			return false;
		}
		Logger.LogInformation("Using GPU: {}", adapters[0].Info.Name);

		// Create device
		if (adapters[0].CreateDevice() not case .Ok(let device))
		{
			Logger.LogCritical("Failed to create GPU device.");
			return false;
		}
		mDevice = device;

		// Create swap chain
		SwapChainDescriptor swapChainDesc = .()
		{
			Width = (uint32)mWindow.Width,
			Height = (uint32)mWindow.Height,
			Format = Parameters.SwapChainFormat,
			Usage = .RenderTarget,
			PresentMode = Parameters.PresentMode
		};

		if (mDevice.CreateSwapChain(mSurface, &swapChainDesc) not case .Ok(let swapChain))
		{
			Logger.LogCritical("Failed to create swap chain.");
			return false;
		}
		mSwapChain = swapChain;
		Logger.LogInformation("Swap chain created: {}x{}", mSwapChain.Width, mSwapChain.Height);

		// --- Jobs ---
		mJobSystem = new JobSystem(Logger);
		mJobSystem.Startup();

		// --- Resources ---
		mResourceSystem = new ResourceSystem(Logger, mJobSystem);
		mResourceSystem.Startup();

		// --- Window Resize Handling ---
		mShell.WindowManager.OnWindowEvent.Subscribe(new => OnWindowEvent);

		Logger.LogInformation("All subsystems initialized.");
		return true;
	}

	protected override void RegisterSubsystems()
	{
		let ctx = Engine.Context;
		ctx.RegisterSubsystem<IShell>(mShell);
		ctx.RegisterSubsystem<IBackend>(mBackend);
		ctx.RegisterSubsystem<IDevice>(mDevice);
		ctx.RegisterSubsystem<ISwapChain>(mSwapChain);
		ctx.RegisterSubsystem<JobSystem>(mJobSystem);
		ctx.RegisterSubsystem<ResourceSystem>(mResourceSystem);
	}

	protected override void ShutdownSubsystems()
	{
		Logger?.LogInformation("Shutting down subsystems...");

		if (mDevice != null)
			mDevice.WaitIdle();

		// Clean up command buffers
		for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
		{
			if (mCommandBuffers[i] != null)
			{
				delete mCommandBuffers[i];
				mCommandBuffers[i] = null;
			}
		}

		// Shutdown in reverse order
		if (mResourceSystem != null)
		{
			mResourceSystem.Shutdown();
			delete mResourceSystem;
			mResourceSystem = null;
		}

		if (mJobSystem != null)
		{
			mJobSystem.Shutdown();
			delete mJobSystem;
			mJobSystem = null;
		}

		if (mSwapChain != null) { delete mSwapChain; mSwapChain = null; }
		if (mDevice != null) { delete mDevice; mDevice = null; }
		if (mSurface != null) { delete mSurface; mSurface = null; }
		if (mBackend != null) { delete mBackend; mBackend = null; }

		if (mShell != null)
		{
			mShell.Shutdown();
			delete mShell;
			mShell = null;
		}

		if (mDefaultLogger != null)
		{
			Logger = null;
			delete mDefaultLogger;
			mDefaultLogger = null;
		}
	}

	/// Discovers the Assets directory by searching from the current directory upward.
	/// The Assets directory is identified by containing a `.assets` marker file.
	private void DiscoverAssetDirectory()
	{
		let currentDir = Directory.GetCurrentDirectory(.. scope .());
		String searchDir = scope .(currentDir);

		while (true)
		{
			let assetsPath = scope String();
			Path.InternalCombine(assetsPath, searchDir, "Assets");

			if (Directory.Exists(assetsPath))
			{
				let markerPath = scope String();
				Path.InternalCombine(markerPath, assetsPath, ".assets");

				if (File.Exists(markerPath))
				{
					mAssetDirectory.Set(assetsPath);
					return;
				}
			}

			let parentDir = Path.GetDirectoryPath(searchDir, .. scope .());

			if (parentDir.IsEmpty || parentDir == searchDir)
			{
				Logger?.LogWarning("Could not find Assets directory with .assets marker. Using 'Assets' relative path.");
				mAssetDirectory.Set("Assets");
				return;
			}

			searchDir.Set(parentDir);
		}
	}

	private void OnWindowEvent(IWindow window, WindowEvent event)
	{
		if (window != mWindow)
			return;

		switch (event.Type)
		{
		case .CloseRequested:
			Exit();
		case .Resized:
			HandleResize();
		default:
		}
	}

	private void HandleResize()
	{
		if (mDevice == null || mSwapChain == null || mWindow == null)
			return;

		mDevice.WaitIdle();

		// Clean up command buffers
		for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
		{
			if (mCommandBuffers[i] != null)
			{
				delete mCommandBuffers[i];
				mCommandBuffers[i] = null;
			}
		}

		// Resize swap chain
		let width = (uint32)mWindow.Width;
		let height = (uint32)mWindow.Height;
		if (width > 0 && height > 0)
		{
			if (mSwapChain.Resize(width, height) case .Err)
			{
				Logger?.LogError("Failed to resize swap chain.");
			}
			else
			{
				Engine.OnResize.[Friend]Invoke((int32)width, (int32)height);
			}
		}
	}
}
