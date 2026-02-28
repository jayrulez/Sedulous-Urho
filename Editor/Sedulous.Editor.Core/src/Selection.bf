using System;
using System.Collections;
using Sedulous.Engine.Core;

namespace Sedulous.Editor.Core;

/// Tracks the set of currently selected nodes and components in the editor.
///
/// Fires SelectionChanged when the selection changes. Supports single and
/// multi-selection. Components are selected through their owning node.
///
public class Selection
{
	private List<Node> mSelectedNodes = new .() ~ delete _;
	private Component mSelectedComponent;

	/// Fired when the selection changes.
	public Event<delegate void()> OnSelectionChanged ~ _.Dispose();

	// ===== Properties =====

	/// The primary selected node (first in list).
	public Node PrimaryNode => mSelectedNodes.Count > 0 ? mSelectedNodes[0] : null;

	/// All selected nodes.
	public Span<Node> SelectedNodes => mSelectedNodes;

	/// The selected component (for inspector focus).
	public Component SelectedComponent => mSelectedComponent;

	/// Number of selected nodes.
	public int Count => mSelectedNodes.Count;

	/// Whether anything is selected.
	public bool HasSelection => mSelectedNodes.Count > 0;

	// ===== Selection Operations =====

	/// Selects a single node, clearing previous selection.
	public void SelectNode(Node node)
	{
		mSelectedNodes.Clear();
		mSelectedComponent = null;

		if (node != null)
			mSelectedNodes.Add(node);

		OnSelectionChanged();
	}

	/// Adds a node to the selection (multi-select).
	public void AddNode(Node node)
	{
		if (node == null || mSelectedNodes.Contains(node))
			return;

		mSelectedNodes.Add(node);
		OnSelectionChanged();
	}

	/// Removes a node from the selection.
	public void RemoveNode(Node node)
	{
		if (mSelectedNodes.Remove(node))
			OnSelectionChanged();
	}

	/// Toggles a node's selection state.
	public void ToggleNode(Node node)
	{
		if (node == null)
			return;

		if (mSelectedNodes.Contains(node))
			mSelectedNodes.Remove(node);
		else
			mSelectedNodes.Add(node);

		OnSelectionChanged();
	}

	/// Selects a specific component (and its owning node).
	public void SelectComponent(Component component)
	{
		mSelectedNodes.Clear();
		mSelectedComponent = component;

		if (component?.Node != null)
			mSelectedNodes.Add(component.Node);

		OnSelectionChanged();
	}

	/// Clears the entire selection.
	public void Clear()
	{
		if (mSelectedNodes.Count == 0 && mSelectedComponent == null)
			return;

		mSelectedNodes.Clear();
		mSelectedComponent = null;
		OnSelectionChanged();
	}

	/// Returns true if the given node is selected.
	public bool IsSelected(Node node)
	{
		return mSelectedNodes.Contains(node);
	}
}
