using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.GUI;

namespace Sedulous.Editor.Core;

/// Editor panel that displays the scene node hierarchy as a tree view.
///
/// Mirrors the scene graph structure. Selecting a tree item updates
/// the editor selection. Context menu provides node creation/deletion.
///
public class SceneHierarchyPanel
{
	private EditorState mEditor;
	private StackPanel mPanel ~ delete _;
	private TreeView mTreeView;
	private ContextMenu mContextMenu ~ delete _;
	private bool mSuppressSelectionSync = false;

	public this(EditorState editor)
	{
		mEditor = editor;
		BuildUI();

		// Subscribe to editor events
		editor.OnSceneChanged.Add(new => OnSceneChanged);
		editor.Selection.OnSelectionChanged.Add(new => OnEditorSelectionChanged);
	}

	/// The root UI element for this panel.
	public StackPanel RootElement => mPanel;

	// ===== UI Construction =====

	private void BuildUI()
	{
		mPanel = new StackPanel();
		mPanel.Orientation = .Vertical;

		// Header label
		let header = new TextBlock();
		header.Text = "Scene Hierarchy";
		mPanel.AddChild(header);

		// Tree view
		mTreeView = new TreeView();
		mTreeView.SelectionChanged.Subscribe(new => OnTreeSelectionChanged);
		mTreeView.IsEditable = true;
		mTreeView.ItemRenamed.Subscribe(new => OnItemRenamed);
		mPanel.AddChild(mTreeView);

		// Context menu
		mContextMenu = new ContextMenu();
		let createItem = mContextMenu.AddItem("Create Child Node");
		createItem.Click.Subscribe(new => OnCreateChildNode);

		mContextMenu.AddSeparator();

		let deleteItem = mContextMenu.AddItem("Delete Node");
		deleteItem.Click.Subscribe(new => OnDeleteNode);

		let renameItem = mContextMenu.AddItem("Rename");
		renameItem.Click.Subscribe(new => OnRenameNode);
	}

	// ===== Tree Rebuild =====

	/// Rebuilds the entire tree from the current scene.
	public void RebuildTree()
	{
		mTreeView.ClearItems();

		let scene = mEditor.Scene;
		if (scene == null)
			return;

		// Add scene root's children
		for (let child in scene.Children)
		{
			let item = AddNodeToTree(child, null);
			if (item != null)
				item.IsExpanded = true;
		}
	}

	private TreeViewItem AddNodeToTree(Node node, TreeViewItem parent)
	{
		let name = node.Name.IsEmpty ? "(unnamed)" : node.Name;

		TreeViewItem item;
		if (parent != null)
			item = parent.AddChild(name);
		else
			item = mTreeView.AddItem(name);

		item.Tag = node;

		// Recurse children
		for (let child in node.Children)
		{
			AddNodeToTree(child, item);
		}

		return item;
	}

	/// Refreshes a single node's display text.
	public void RefreshNode(Node node)
	{
		let item = FindItem(node);
		if (item != null)
		{
			let name = node.Name.IsEmpty ? "(unnamed)" : node.Name;
			item.Text = name;
		}
	}

	/// Finds the tree view item for a given node.
	private TreeViewItem FindItem(Node node)
	{
		for (int i = 0; i < mTreeView.ItemCount; i++)
		{
			let result = FindItemRecursive(mTreeView.GetItem(i), node);
			if (result != null)
				return result;
		}
		return null;
	}

	private TreeViewItem FindItemRecursive(TreeViewItem item, Node node)
	{
		if (item.Tag === node)
			return item;

		for (int i = 0; i < item.ChildCount; i++)
		{
			let result = FindItemRecursive(item.GetChild(i), node);
			if (result != null)
				return result;
		}

		return null;
	}

	// ===== Event Handlers =====

	private void OnSceneChanged(Scene scene)
	{
		RebuildTree();
	}

	private void OnTreeSelectionChanged(TreeView treeView)
	{
		if (mSuppressSelectionSync)
			return;

		let selectedItem = treeView.SelectedItem;
		if (selectedItem != null)
		{
			let node = selectedItem.Tag as Node;
			if (node != null)
			{
				mSuppressSelectionSync = true;
				mEditor.Selection.SelectNode(node);
				mSuppressSelectionSync = false;
			}
		}
		else
		{
			mSuppressSelectionSync = true;
			mEditor.Selection.Clear();
			mSuppressSelectionSync = false;
		}
	}

	private void OnEditorSelectionChanged()
	{
		if (mSuppressSelectionSync)
			return;

		mSuppressSelectionSync = true;

		let node = mEditor.Selection.PrimaryNode;
		if (node != null)
		{
			let item = FindItem(node);
			if (item != null)
			{
				mTreeView.SelectedItem = item;
				mTreeView.ScrollIntoView(item);
			}
		}
		else
		{
			mTreeView.SelectedItem = null;
		}

		mSuppressSelectionSync = false;
	}

	private void OnItemRenamed(TreeView treeView, TreeViewItem item, StringView newText)
	{
		let node = item.Tag as Node;
		if (node != null)
		{
			let cmd = new RenameNodeCommand(node, newText);
			mEditor.ExecuteCommand(cmd);
		}
	}

	private void OnCreateChildNode(MenuItem item)
	{
		let selectedNode = mEditor.Selection.PrimaryNode ?? mEditor.Scene;
		if (selectedNode == null)
			return;

		let cmd = new CreateNodeCommand(selectedNode, "NewNode");
		mEditor.ExecuteCommand(cmd);
		RebuildTree();
	}

	private void OnDeleteNode(MenuItem item)
	{
		let node = mEditor.Selection.PrimaryNode;
		if (node == null)
			return;

		let cmd = new DeleteNodeCommand(node);
		mEditor.ExecuteCommand(cmd);
		mEditor.Selection.Clear();
		RebuildTree();
	}

	private void OnRenameNode(MenuItem item)
	{
		if (mTreeView.SelectedItem != null)
			mTreeView.BeginEdit();
	}

	/// Shows the context menu at the given position.
	public void ShowContextMenu(Vector2 position)
	{
		mContextMenu.Show(mPanel, position);
	}
}
