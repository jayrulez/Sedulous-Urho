using System;
using Sedulous.Engine.Core;

namespace Sedulous.Editor.Core;

/// The mode the editor is currently in.
public enum EditorMode
{
	/// Normal editing mode.
	Edit,
	/// Playing the scene (simulation running).
	Play,
	/// Play mode is paused.
	Paused
}

/// The active transform manipulation mode.
public enum GizmoMode
{
	/// Translate (move) gizmo.
	Translate,
	/// Rotate gizmo.
	Rotate,
	/// Scale gizmo.
	Scale
}

/// The coordinate space for gizmo operations.
public enum GizmoSpace
{
	/// World-aligned axes.
	World,
	/// Object-local axes.
	Local
}

/// Central editor state — holds the scene, selection, undo/redo, and mode.
///
/// All editor panels read from and write to this shared state object.
/// Changes to state fire events that panels subscribe to for updates.
///
public class EditorState
{
	private Scene mScene;
	private String mSavedSceneXml ~ delete _; // Serialized scene for play mode restore
	private Context mContext;
	private EditorMode mMode = .Edit;
	private GizmoMode mGizmoMode = .Translate;
	private GizmoSpace mGizmoSpace = .World;
	private bool mGridVisible = true;

	/// Node/component selection tracker.
	public Selection Selection { get; private set; } ~ delete _;

	/// Undo/redo command history.
	public CommandHistory CommandHistory { get; private set; } ~ delete _;

	/// Fired when the active scene changes.
	public Event<delegate void(Scene)> OnSceneChanged ~ _.Dispose();

	/// Fired when the editor mode changes (Edit/Play/Paused).
	public Event<delegate void(EditorMode)> OnModeChanged ~ _.Dispose();

	/// Fired when the gizmo mode changes.
	public Event<delegate void(GizmoMode)> OnGizmoModeChanged ~ _.Dispose();

	public this(Context context)
	{
		mContext = context;
		Selection = new .();
		CommandHistory = new .();
	}

	// ===== Properties =====

	/// The engine context.
	public Context Context => mContext;

	/// The scene currently being edited.
	public Scene Scene => mScene;

	/// Current editor mode.
	public EditorMode Mode => mMode;

	/// Current gizmo manipulation mode.
	public GizmoMode GizmoMode
	{
		get => mGizmoMode;
		set
		{
			if (mGizmoMode != value)
			{
				mGizmoMode = value;
				OnGizmoModeChanged(value);
			}
		}
	}

	/// Coordinate space for gizmo operations.
	public GizmoSpace GizmoSpace
	{
		get => mGizmoSpace;
		set => mGizmoSpace = value;
	}

	/// Whether the editor grid is visible.
	public bool GridVisible
	{
		get => mGridVisible;
		set => mGridVisible = value;
	}

	/// Whether we're in edit mode (not playing).
	public bool IsEditing => mMode == .Edit;

	/// Whether the scene is currently playing.
	public bool IsPlaying => mMode == .Play || mMode == .Paused;

	// ===== Scene Management =====

	/// Sets the active scene.
	public void SetScene(Scene scene)
	{
		if (mScene == scene)
			return;

		Selection.Clear();
		CommandHistory.Clear();
		mScene = scene;
		OnSceneChanged(scene);
	}

	/// Creates a new empty scene.
	public void NewScene()
	{
		if (mScene != null)
		{
			mScene.Clear();
		}
		else
		{
			SetScene(new Scene());
		}

		Selection.Clear();
		CommandHistory.Clear();
	}

	// ===== Play Mode =====

	/// Enters play mode. Saves scene state for later restore.
	public void EnterPlayMode()
	{
		if (mMode != .Edit)
			return;

		// Serialize scene state so we can restore it when exiting play mode
		if (mScene != null)
		{
			delete mSavedSceneXml;
			mSavedSceneXml = new String();
			SceneSerializer.SaveScene(mScene, mSavedSceneXml);
		}

		Selection.Clear();
		mMode = .Play;
		OnModeChanged(.Play);
	}

	/// Pauses play mode.
	public void PausePlayMode()
	{
		if (mMode != .Play)
			return;

		mMode = .Paused;
		OnModeChanged(.Paused);
	}

	/// Resumes from paused play mode.
	public void ResumePlayMode()
	{
		if (mMode != .Paused)
			return;

		mMode = .Play;
		OnModeChanged(.Play);
	}

	/// Exits play mode. Restores scene to pre-play state.
	public void ExitPlayMode()
	{
		if (mMode == .Edit)
			return;

		// Restore serialized scene state
		if (mScene != null && mSavedSceneXml != null && !mSavedSceneXml.IsEmpty)
		{
			SceneSerializer.LoadScene(mScene, mSavedSceneXml, mContext);
		}
		DeleteAndNullify!(mSavedSceneXml);

		Selection.Clear();
		CommandHistory.Clear();
		mMode = .Edit;
		OnModeChanged(.Edit);
	}

	// ===== Command Shortcuts =====

	/// Executes a command through the undo/redo system.
	public void ExecuteCommand(IEditorCommand command)
	{
		CommandHistory.Execute(command);
	}

	/// Undoes the last command.
	public void Undo()
	{
		CommandHistory.Undo();
	}

	/// Redoes the last undone command.
	public void Redo()
	{
		CommandHistory.Redo();
	}
}
