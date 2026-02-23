using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using internal Sedulous.Engine.Core;

namespace Sedulous.Engine.Core;

/// A node in the scene graph hierarchy.
///
/// Nodes form a tree with parent-child relationships. Each node has a local
/// transform (position, rotation, scale) that is composed with its parent's
/// world transform to produce the node's world transform.
///
/// Nodes hold components that provide functionality (rendering, physics, etc.)
/// and can be identified by name and tags.
///
public class Node
{
	// Transform (local space)
	private Vector3 mPosition = .Zero;
	private Quaternion mRotation = .Identity;
	private Vector3 mScale = .One;

	// Cached world transform
	private Matrix mWorldTransform = .Identity;
	private bool mWorldTransformDirty = true;

	// Hierarchy
	private Node mParent;
	private List<Node> mChildren = new .() ~ DeleteContainerAndItems!(_);
	private List<Component> mComponents = new .() ~ {
		for (let c in _)
		{
			c.NotifyRemoved();
			delete c;
		}
		delete _;
	};

	// Identity
	private String mName = new .() ~ delete _;
	private HashSet<String> mTags = new .() ~ DeleteContainerAndItems!(_);
	private uint32 mId = 0;
	private bool mEnabled = true;

	// Scene reference (not owned)
	private Scene mScene;

	// ===== Properties =====

	/// The parent node. Null for root nodes and the Scene itself.
	public Node Parent => mParent;

	/// The scene this node belongs to. Null if not in a scene.
	public Scene Scene => mScene;

	/// Unique ID within the scene. Zero if not in a scene.
	public uint32 ID => mId;

	/// Number of child nodes.
	public int ChildCount => mChildren.Count;

	/// Number of attached components.
	public int ComponentCount => mComponents.Count;

	// ===== Name =====

	/// Gets the node name.
	public StringView Name => mName;

	/// Sets the node name.
	public void SetName(StringView name)
	{
		mName.Set(name);
	}

	// ===== Enabled =====

	/// Whether this node is enabled. Disabling a node cascades to children and components.
	public bool Enabled
	{
		get => mEnabled;
		set
		{
			if (mEnabled == value)
				return;
			mEnabled = value;
		}
	}

	/// Whether this node is effectively enabled (itself and all ancestors are enabled).
	public bool EnabledEffective
	{
		get
		{
			if (!mEnabled)
				return false;
			if (mParent != null)
				return mParent.EnabledEffective;
			return true;
		}
	}

	// ===== Local Transform =====

	/// Local position relative to parent.
	public Vector3 Position
	{
		get => mPosition;
		set
		{
			mPosition = value;
			MarkTransformDirty();
		}
	}

	/// Local rotation relative to parent.
	public Quaternion Rotation
	{
		get => mRotation;
		set
		{
			mRotation = value;
			MarkTransformDirty();
		}
	}

	/// Local scale relative to parent.
	public Vector3 Scale
	{
		get => mScale;
		set
		{
			mScale = value;
			MarkTransformDirty();
		}
	}

	/// Sets position, rotation, and scale atomically (single dirty notification).
	public void SetTransform(Vector3 position, Quaternion rotation, Vector3 scale)
	{
		mPosition = position;
		mRotation = rotation;
		mScale = scale;
		MarkTransformDirty();
	}

	/// Sets position and rotation atomically (scale unchanged).
	public void SetTransform(Vector3 position, Quaternion rotation)
	{
		mPosition = position;
		mRotation = rotation;
		MarkTransformDirty();
	}

	// ===== World Transform =====

	/// The world transform matrix (local-to-world).
	/// Lazily computed and cached using dirty flags.
	public Matrix WorldTransform
	{
		get
		{
			if (mWorldTransformDirty)
				UpdateWorldTransform();
			return mWorldTransform;
		}
	}

	/// World-space position.
	public Vector3 WorldPosition
	{
		get => WorldTransform.Translation;
		set
		{
			if (mParent != null)
			{
				// Convert world position to local
				Matrix parentInverse = .Identity;
				if (Matrix.TryInvert(mParent.WorldTransform, out parentInverse))
					Position = Vector3.Transform(value, parentInverse);
				else
					Position = value;
			}
			else
			{
				Position = value;
			}
		}
	}

	/// World-space rotation.
	public Quaternion WorldRotation
	{
		get
		{
			if (mParent != null)
				return Quaternion.Multiply(mParent.WorldRotation, mRotation);
			return mRotation;
		}
		set
		{
			if (mParent != null)
				Rotation = Quaternion.Multiply(Quaternion.Inverse(mParent.WorldRotation), value);
			else
				Rotation = value;
		}
	}

	/// The forward direction in world space (negative Z axis of local frame).
	public Vector3 WorldDirection
	{
		get => Vector3.Transform(.Forward, WorldRotation);
	}

	/// The right direction in world space (positive X axis of local frame).
	public Vector3 WorldRight
	{
		get => Vector3.Transform(.Right, WorldRotation);
	}

	/// The up direction in world space (positive Y axis of local frame).
	public Vector3 WorldUp
	{
		get => Vector3.Transform(.Up, WorldRotation);
	}

	// ===== Child Management =====

	/// Creates a new child node with an optional name.
	public Node CreateChild(StringView name = "")
	{
		let child = new Node();
		child.SetName(name);
		AddChild(child);
		return child;
	}

	/// Adds an existing node as a child. Removes it from its previous parent.
	public void AddChild(Node child)
	{
		if (child == null || child == this)
			return;

		// Prevent adding an ancestor as a child (would create a cycle)
		Node ancestor = mParent;
		while (ancestor != null)
		{
			if (ancestor == child)
				return;
			ancestor = ancestor.mParent;
		}

		// Remove from previous parent
		if (child.mParent != null)
			child.mParent.RemoveChildInternal(child);

		child.mParent = this;
		mChildren.Add(child);
		child.MarkTransformDirty();

		// Propagate scene if we're in one
		if (mScene != null)
			child.SetSceneRecursive(mScene);
	}

	/// Removes a child node. Returns true if the child was found and removed.
	/// The removed node is NOT deleted — the caller takes ownership.
	public bool RemoveChild(Node child)
	{
		if (child == null || child.mParent != this)
			return false;

		// Unregister from scene
		if (child.mScene != null)
			child.SetSceneRecursive(null);

		RemoveChildInternal(child);
		return true;
	}

	/// Removes and deletes a child node.
	public void DestroyChild(Node child)
	{
		if (RemoveChild(child))
			delete child;
	}

	/// Removes and deletes all children.
	public void DestroyAllChildren()
	{
		for (let child in mChildren)
		{
			if (child.mScene != null)
				child.SetSceneRecursive(null);
			child.mParent = null;
			delete child;
		}
		mChildren.Clear();
	}

	/// Gets a child by index.
	public Node GetChild(int index)
	{
		if (index >= 0 && index < mChildren.Count)
			return mChildren[index];
		return null;
	}

	/// Finds a child by name (direct children only).
	public Node GetChild(StringView name)
	{
		for (let child in mChildren)
		{
			if (child.mName == name)
				return child;
		}
		return null;
	}

	/// Finds a descendant by name (recursive search, depth-first).
	public Node FindChild(StringView name)
	{
		for (let child in mChildren)
		{
			if (child.mName == name)
				return child;
			let found = child.FindChild(name);
			if (found != null)
				return found;
		}
		return null;
	}

	/// Gets a read-only view of the children list.
	public Span<Node> Children => mChildren;

	// ===== Component Management =====

	/// Creates and attaches a new component of type T.
	public T CreateComponent<T>() where T : Component, new
	{
		let component = new T();
		AddComponent(component);
		return component;
	}

	/// Attaches an existing component to this node.
	/// The node takes ownership of the component.
	public void AddComponent(Component component)
	{
		if (component == null)
			return;

		// Remove from previous node if any
		if (component.Node != null)
			component.Node.RemoveComponent(component);

		mComponents.Add(component);
		component.SetNode(this);

		// Register with scene if we're in one
		if (mScene != null)
			mScene.RegisterComponent(component);
	}

	/// Removes a component from this node. Returns true if found.
	/// The removed component is NOT deleted — the caller takes ownership.
	public bool RemoveComponent(Component component)
	{
		if (component == null || component.Node != this)
			return false;

		// Unregister from scene
		if (mScene != null)
			mScene.UnregisterComponent(component);

		component.NotifyRemoved();
		component.SetNode(null);
		mComponents.Remove(component);
		return true;
	}

	/// Removes and deletes a component.
	public void DestroyComponent(Component component)
	{
		if (RemoveComponent(component))
			delete component;
	}

	/// Gets the first component of type T attached to this node.
	public T GetComponent<T>() where T : Component
	{
		for (let component in mComponents)
		{
			if (let typed = component as T)
				return typed;
		}
		return null;
	}

	/// Gets all components of type T attached to this node.
	public void GetComponents<T>(List<T> results) where T : Component
	{
		for (let component in mComponents)
		{
			if (let typed = component as T)
				results.Add(typed);
		}
	}

	/// Gets a read-only view of all components.
	public Span<Component> Components => mComponents;

	// ===== Tags =====

	/// Adds a tag to this node.
	public void AddTag(StringView tag)
	{
		if (tag.IsEmpty)
			return;

		let tagStr = new String(tag);
		if (mTags.Add(tagStr))
		{
			// Register with scene tag index
			mScene?.AddNodeTag(this, tagStr);
		}
		else
		{
			delete tagStr;
		}
	}

	/// Removes a tag from this node.
	public bool RemoveTag(StringView tag)
	{
		if (tag.IsEmpty)
			return false;

		//if (mTags.TryGet(scope String(tag), let existing))
		if (mTags.GetAndRemove(scope String(tag)) case .Ok(let existing))
		{
			mScene?.RemoveNodeTag(this, existing);
			//mTags.Remove(existing);
			delete existing;
			return true;
		}
		return false;
	}

	/// Returns true if this node has the specified tag.
	public bool HasTag(StringView tag)
	{
		return mTags.Contains(scope String(tag));
	}

	/// Removes all tags from this node.
	public void RemoveAllTags()
	{
		for (let tag in mTags)
		{
			mScene?.RemoveNodeTag(this, tag);
			delete tag;
		}
		mTags.Clear();
	}

	// ===== Internal =====

	/// Sets the node's ID. Called by Scene on registration.
	internal void SetID(uint32 id)
	{
		mId = id;
	}

	/// Marks the world transform as dirty and propagates to children and components.
	private void MarkTransformDirty()
	{
		if (mWorldTransformDirty)
			return; // Already dirty, children must be dirty too

		mWorldTransformDirty = true;

		// Notify components
		for (let component in mComponents)
			component.NotifyTransformChanged();

		// Propagate to children
		for (let child in mChildren)
			child.MarkTransformDirty();
	}

	/// Recomputes the world transform from parent and local transform.
	private void UpdateWorldTransform()
	{
		let localMatrix = Matrix.CreateFromTranslationRotationScale(mPosition, mRotation, mScale);

		if (mParent != null)
			mWorldTransform = Matrix.Multiply(localMatrix, mParent.WorldTransform);
		else
			mWorldTransform = localMatrix;

		mWorldTransformDirty = false;
	}

	/// Removes a child from the internal list without scene cleanup.
	private void RemoveChildInternal(Node child)
	{
		child.mParent = null;
		mChildren.Remove(child);
	}

	/// Recursively sets the scene reference for this node and all descendants.
	internal void SetSceneRecursive(Scene scene)
	{
		let previousScene = mScene;
		mScene = scene;

		if (scene != null && previousScene == null)
		{
			// Entering a scene — register this node and its components
			scene.RegisterNode(this);
			for (let component in mComponents)
				scene.RegisterComponent(component);
			// Register existing tags with the scene's tag index
			for (let tag in mTags)
				scene.AddNodeTag(this, tag);
		}
		else if (scene == null && previousScene != null)
		{
			// Leaving a scene — unregister
			for (let component in mComponents)
			{
				previousScene.UnregisterComponent(component);
				component.SetScene(null);
			}
			// Unregister tags
			for (let tag in mTags)
				previousScene.RemoveNodeTag(this, tag);
			previousScene.UnregisterNode(this);
		}

		// Recurse into children
		for (let child in mChildren)
			child.SetSceneRecursive(scene);
	}
}
