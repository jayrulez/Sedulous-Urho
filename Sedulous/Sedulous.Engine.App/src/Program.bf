using System;
using Sedulous.Engine.Core;
using Sedulous.Shell.Input;

namespace Sedulous.Engine.App;

/// Minimal demo application that opens a window and runs the engine frame loop.
class DemoApp : SedulousApp
{
	protected override void Setup()
	{
		Parameters.WindowTitle = "Sedulous Engine";
		Parameters.WindowWidth = 1280;
		Parameters.WindowHeight = 720;
	}

	protected override void Start()
	{
		Logger?.LogInformation("DemoApp started. Press Escape to exit.");

		// Subscribe to update to check for escape key
		Engine.OnUpdate.Subscribe(new => OnUpdate);
	}

	protected override void Stop()
	{
		Logger?.LogInformation("DemoApp stopped.");
	}

	private void OnUpdate(float timeStep)
	{
		let shell = Context.GetSubsystem<Sedulous.Shell.IShell>();
		if (shell != null && shell.InputManager.Keyboard.IsKeyPressed(.Escape))
		{
			Exit();
		}
	}
}

class Program
{
	static void Main()
	{
		let app = scope DemoApp();
		let exitCode = app.Run();
		if (exitCode != 0)
			Console.Error.WriteLine(scope $"Application exited with code {exitCode}");
	}
}
