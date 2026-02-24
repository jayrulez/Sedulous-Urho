using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.Engine.App;
using Sedulous.Shell;
using Sedulous.Shell.Input;
using Sedulous.GUI;
using Sedulous.Editor.Core;

namespace Sedulous.Editor.App;

/// The main editor application.
///
/// Sets up the editor window with a docking layout, menu bar, toolbar,
/// scene hierarchy panel, inspector panel, and viewport placeholder.
///
class EditorApp : SedulousApp
{
	private GUIContext mGuiContext ~ delete _;
	private EditorState mEditorState ~ delete _;
	private SceneHierarchyPanel mHierarchyPanel ~ delete _;
	private InspectorPanel mInspectorPanel ~ delete _;
	private DockManager mDockManager;

	// Input tracking for GUI forwarding
	private float mLastMouseX = 0;
	private float mLastMouseY = 0;
	private bool mLastMouseLeft = false;
	private bool mLastMouseRight = false;
	private bool mLastMouseMiddle = false;

	protected override void Setup()
	{
		Parameters.WindowTitle = "Sedulous Editor";
		Parameters.WindowWidth = 1600;
		Parameters.WindowHeight = 900;
		Parameters.WindowResizable = true;
	}

	protected override void Start()
	{
		Logger?.LogInformation("Editor starting...");

		// Create editor state with a default scene
		mEditorState = new EditorState(Context);
		mEditorState.NewScene();

		// Create GUI context
		mGuiContext = new GUIContext();
		mGuiContext.SetViewportSize((float)Window.Width, (float)Window.Height);

		// Build the main layout
		let rootPanel = new StackPanel();
		rootPanel.Orientation = .Vertical;
		mGuiContext.RootElement = rootPanel;

		BuildMenuBar(rootPanel);
		BuildToolBar(rootPanel);
		BuildDockLayout(rootPanel);

		// Subscribe to engine events
		Engine.OnUpdate.Subscribe(new => OnUpdate);
		Engine.OnResize.Subscribe(new => OnResize);

		Logger?.LogInformation("Editor started.");
	}

	protected override void Stop()
	{
		Logger?.LogInformation("Editor stopping...");
	}

	// ===== UI Construction =====

	private void BuildMenuBar(StackPanel root)
	{
		let menu = new Menu();

		// --- File ---
		let fileMenu = menu.AddItem("&File");

		let newItem = fileMenu.AddDropdownItem("&New Scene");
		newItem.ShortcutText = "Ctrl+N";
		newItem.Click.Subscribe(new (item) => {
			mEditorState.NewScene();
			mHierarchyPanel?.RebuildTree();
		});

		fileMenu.AddDropdownSeparator();

		let exitItem = fileMenu.AddDropdownItem("E&xit");
		exitItem.Click.Subscribe(new (item) => Exit());

		// --- Edit ---
		let editMenu = menu.AddItem("&Edit");

		let undoItem = editMenu.AddDropdownItem("&Undo");
		undoItem.ShortcutText = "Ctrl+Z";
		undoItem.Click.Subscribe(new (item) => {
			mEditorState.Undo();
			mInspectorPanel?.RefreshValues();
		});

		let redoItem = editMenu.AddDropdownItem("&Redo");
		redoItem.ShortcutText = "Ctrl+Y";
		redoItem.Click.Subscribe(new (item) => {
			mEditorState.Redo();
			mInspectorPanel?.RefreshValues();
		});

		// --- View ---
		let viewMenu = menu.AddItem("&View");
		viewMenu.AddDropdownItem("&Scene Hierarchy");
		viewMenu.AddDropdownItem("&Inspector");

		root.AddChild(menu);
	}

	private void BuildToolBar(StackPanel root)
	{
		let toolbar = new ToolBar();
		toolbar.Orientation = .Horizontal;

		// Play/Stop
		let playBtn = toolbar.AddButton("Play");
		playBtn.Click.Subscribe(new (btn) => {
			if (mEditorState.IsPlaying)
				mEditorState.ExitPlayMode();
			else
				mEditorState.EnterPlayMode();
		});

		toolbar.AddSeparator();

		// Transform mode toggle buttons
		let translateBtn = toolbar.AddToggleButton("Move");
		translateBtn.IsChecked = true;
		translateBtn.Checked.Subscribe(new (btn, isChecked) => {
			if (isChecked)
				mEditorState.GizmoMode = .Translate;
		});

		let rotateBtn = toolbar.AddToggleButton("Rotate");
		rotateBtn.Checked.Subscribe(new (btn, isChecked) => {
			if (isChecked)
				mEditorState.GizmoMode = .Rotate;
		});

		let scaleBtn = toolbar.AddToggleButton("Scale");
		scaleBtn.Checked.Subscribe(new (btn, isChecked) => {
			if (isChecked)
				mEditorState.GizmoMode = .Scale;
		});

		root.AddChild(toolbar);
	}

	private void BuildDockLayout(StackPanel root)
	{
		mDockManager = new DockManager();

		// Viewport (center, added first)
		let viewportLabel = new TextBlock();
		viewportLabel.Text = "3D Viewport";
		let viewportDock = new DockablePanel("Viewport", viewportLabel);
		mDockManager.AddPanel(viewportDock);

		// Scene hierarchy (left)
		mHierarchyPanel = new SceneHierarchyPanel(mEditorState);
		let hierarchyDock = new DockablePanel("Scene Hierarchy", mHierarchyPanel.RootElement);
		mDockManager.DockPanel(hierarchyDock, .Left);

		// Inspector (right)
		mInspectorPanel = new InspectorPanel(mEditorState);
		let inspectorDock = new DockablePanel("Inspector", mInspectorPanel.RootElement);
		mDockManager.DockPanel(inspectorDock, .Right);

		root.AddChild(mDockManager);
	}

	// ===== Per-Frame Update =====

	private void OnUpdate(float timeStep)
	{
		// Forward input from Shell to GUI
		ForwardInput();

		// Update GUI
		mGuiContext?.Update(timeStep, 0);

		// Keyboard shortcuts
		let shell = Context.GetSubsystem<IShell>();
		if (shell != null)
		{
			let kb = shell.InputManager.Keyboard;
			if (kb.IsKeyPressed(.Escape))
				Exit();
		}
	}

	private void OnResize(int32 width, int32 height)
	{
		mGuiContext?.SetViewportSize((float)width, (float)height);
	}

	// ===== Input Forwarding =====

	private void ForwardInput()
	{
		let shell = Context.GetSubsystem<IShell>();
		if (shell == null || mGuiContext == null)
			return;

		let mouse = shell.InputManager.Mouse;
		let mx = mouse.X;
		let my = mouse.Y;

		// Mouse move
		if (mx != mLastMouseX || my != mLastMouseY)
		{
			mGuiContext.ProcessMouseMove(mx, my);
			mLastMouseX = mx;
			mLastMouseY = my;
		}

		// Left button
		let leftDown = mouse.IsButtonDown(.Left);
		if (leftDown && !mLastMouseLeft)
			mGuiContext.ProcessMouseDown(mx, my, .Left);
		else if (!leftDown && mLastMouseLeft)
			mGuiContext.ProcessMouseUp(mx, my, .Left);
		mLastMouseLeft = leftDown;

		// Right button
		let rightDown = mouse.IsButtonDown(.Right);
		if (rightDown && !mLastMouseRight)
			mGuiContext.ProcessMouseDown(mx, my, .Right);
		else if (!rightDown && mLastMouseRight)
			mGuiContext.ProcessMouseUp(mx, my, .Right);
		mLastMouseRight = rightDown;

		// Middle button
		let middleDown = mouse.IsButtonDown(.Middle);
		if (middleDown && !mLastMouseMiddle)
			mGuiContext.ProcessMouseDown(mx, my, .Middle);
		else if (!middleDown && mLastMouseMiddle)
			mGuiContext.ProcessMouseUp(mx, my, .Middle);
		mLastMouseMiddle = middleDown;

		// Scroll
		let scrollY = mouse.ScrollY;
		if (scrollY != 0)
			mGuiContext.ProcessMouseWheel(mx, my, scrollY);
	}
}

class Program
{
	static void Main()
	{
		let app = scope EditorApp();
		let exitCode = app.Run();
		if (exitCode != 0)
			Console.Error.WriteLine(scope $"Editor exited with code {exitCode}");
	}
}
