using System;
using System.Collections;
using internal Sedulous.Engine.Core;

namespace Sedulous.Engine.Core;

/// The scene is the root of the scene graph hierarchy.
///
/// Scene extends Node and acts as the root node. It maintains registries for
/// fast lookup of nodes by ID, components by ID, and nodes by tag. All nodes
/// and components in the scene are assigned unique IDs upon registration.
///
/// The scene also provides time scaling and can be paused independently.
///
public class Scene : Node
{
	// ID generators
	private uint32 mNextNodeId = 1;
	private uint32 mNextComponentId = 1;

	// Registries
	private Dictionary<uint32, Node> mNodes = new .() ~ delete _;
	private Dictionary<uint32, Component> mComponents = new .() ~ delete _;
	private Dictionary<String, List<Node>> mTaggedNodes = new .() ~ {
		for (let pair in _)
		{
			delete pair.key;
			delete pair.value;
		}
		delete _;
	};

	// Scene-level state
	private float mTimeScale = 1.0f;
	private float mElapsedTime = 0.0f;
	private bool mUpdateEnabled = true;

	// ===== Properties =====

	/// Time scaling factor for scene updates. 1.0 = normal speed.
	public float TimeScale
	{
		get => mTimeScale;
		set => mTimeScale = Math.Max(value, 0.0f);
	}

	/// Total elapsed scene time (respects TimeScale).
	public float ElapsedTime => mElapsedTime;

	/// Whether scene updates are enabled.
	public bool UpdateEnabled
	{
		get => mUpdateEnabled;
		set => mUpdateEnabled = value;
	}

	/// Number of registered nodes (excluding the scene root itself).
	public int NodeCount => mNodes.Count;

	/// Number of registered components.
	public int RegisteredComponentCount => mComponents.Count;

	// ===== Construction =====

	public this()
	{
		SetName("Scene");
		// Scene is its own root — register itself in the scene graph
		SetSceneRecursive(this);
	}

	// ===== Queries =====

	/// Finds a node by its scene-unique ID. Returns null if not found.
	public Node GetNode(uint32 id)
	{
		if (mNodes.TryGetValue(id, let node))
			return node;
		return null;
	}

	/// Finds a component by its scene-unique ID. Returns null if not found.
	public Component GetComponentByID(uint32 id)
	{
		if (mComponents.TryGetValue(id, let component))
			return component;
		return null;
	}

	/// Gets all nodes with the specified tag.
	public void GetNodesWithTag(StringView tag, List<Node> results)
	{
		if (mTaggedNodes.TryGetValue(scope String(tag), let nodes))
		{
			for (let node in nodes)
				results.Add(node);
		}
	}

	// ===== Update =====

	/// Advances the scene by the given timestep (scaled by TimeScale).
	public void Update(float timeStep)
	{
		if (!mUpdateEnabled)
			return;

		float scaledStep = timeStep * mTimeScale;
		mElapsedTime += scaledStep;
	}

	// ===== Scene Clearing =====

	/// Removes all child nodes and their components, resetting the scene.
	/// The scene root node itself is preserved.
	public void Clear()
	{
		DestroyAllChildren();

		// Clear registries (nodes/components were unregistered during destroy)
		mNodes.Clear();
		mComponents.Clear();
		for (let pair in mTaggedNodes)
		{
			delete pair.key;
			delete pair.value;
		}
		mTaggedNodes.Clear();

		// Re-register the scene itself
		mNextNodeId = 1;
		mNextComponentId = 1;
		RegisterNode(this);
	}

	// ===== Internal Registration (called by Node) =====

	/// Registers a node in the scene, assigning it a unique ID.
	internal void RegisterNode(Node node)
	{
		let id = mNextNodeId++;
		node.SetID(id);
		mNodes[id] = node;
	}

	/// Unregisters a node from the scene.
	internal void UnregisterNode(Node node)
	{
		if (node.ID != 0)
		{
			mNodes.Remove(node.ID);
			node.SetID(0);
		}
	}

	/// Registers a component in the scene, assigning it a unique ID.
	internal void RegisterComponent(Component component)
	{
		let id = mNextComponentId++;
		component.SetID(id);
		component.SetScene(this);
		mComponents[id] = component;
	}

	/// Unregisters a component from the scene.
	internal void UnregisterComponent(Component component)
	{
		if (component.ID != 0)
		{
			mComponents.Remove(component.ID);
			component.SetID(0);
		}
	}

	/// Adds a node-tag mapping to the scene's tag index.
	/// The tag string is NOT owned by the scene — it is owned by the Node's tag set.
	internal void AddNodeTag(Node node, String tag)
	{
		List<Node> nodes;
		if (!mTaggedNodes.TryGetValue(tag, out nodes))
		{
			let key = new String(tag);
			nodes = new List<Node>();
			mTaggedNodes[key] = nodes;
		}
		if (!nodes.Contains(node))
			nodes.Add(node);
	}

	/// Removes a node-tag mapping from the scene's tag index.
	internal void RemoveNodeTag(Node node, String tag)
	{
		if (mTaggedNodes.TryGetValue(tag, let nodes))
		{
			nodes.Remove(node);
		}
	}
}
