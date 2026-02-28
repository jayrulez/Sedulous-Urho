using System;

namespace Sedulous.Engine.Core;

/// Base class for all components that can be attached to nodes.
///
/// Components provide functionality to nodes — rendering, physics, audio, etc.
/// All game behavior is implemented as Component subclasses decorated with
/// [EngineComponent] for reflection-based registration.
///
/// Lifecycle:
///   1. Created (constructor)
///   2. Attached to Node → OnNodeSet()
///   3. Node enters Scene → OnSceneSet()
///   4. Enabled/Disabled → OnEnabled() / OnDisabled()
///   5. Node transforms → OnTransformChanged()
///   6. Detached from Node → OnRemoved()
///
public class Component
{
	private Node mNode;
	private Scene mScene;
	private bool mEnabled = true;
	private uint32 mId = 0;

	/// The node this component is attached to. Null if not attached.
	public Node Node => mNode;

	/// The scene this component belongs to. Null if the node is not in a scene.
	public Scene Scene => mScene;

	/// Whether this component is enabled. A disabled component still exists
	/// on the node but doesn't participate in updates or rendering.
	public bool Enabled
	{
		get => mEnabled;
		set
		{
			if (mEnabled == value)
				return;
			mEnabled = value;
			if (mEnabled)
				OnEnabled();
			else
				OnDisabled();
		}
	}

	/// Whether this component is effectively enabled (itself and its node are both enabled).
	public bool EnabledEffective => mEnabled && (mNode == null || mNode.EnabledEffective);

	/// Unique ID within the scene. Zero if not in a scene.
	public uint32 ID => mId;

	// ===== Lifecycle Hooks (override in subclasses) =====

	/// Called when this component is attached to a node.
	protected virtual void OnNodeSet(Node node) { }

	/// Called when the owning node enters or leaves a scene.
	/// scene is null when leaving a scene.
	protected virtual void OnSceneSet(Scene scene) { }

	/// Called when the component is enabled.
	protected virtual void OnEnabled() { }

	/// Called when the component is disabled.
	protected virtual void OnDisabled() { }

	/// Called when the owning node's world transform changes.
	protected virtual void OnTransformChanged() { }

	/// Called just before the component is removed from its node.
	protected virtual void OnRemoved() { }

	// ===== Internal (called by Node/Scene) =====

	/// Sets the owning node. Called by Node when attaching/detaching.
	internal void SetNode(Node node)
	{
		mNode = node;
		OnNodeSet(node);
	}

	/// Sets the scene reference. Called by Node when entering/leaving a scene.
	internal void SetScene(Scene scene)
	{
		mScene = scene;
		OnSceneSet(scene);
	}

	/// Assigns a unique ID. Called by Scene on registration.
	internal void SetID(uint32 id)
	{
		mId = id;
	}

	/// Notifies that the owning node's transform changed.
	internal void NotifyTransformChanged()
	{
		if (mEnabled)
			OnTransformChanged();
	}

	/// Called by Node just before removal.
	internal void NotifyRemoved()
	{
		OnRemoved();
	}
}
