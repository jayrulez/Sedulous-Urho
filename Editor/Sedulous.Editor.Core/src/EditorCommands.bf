using System;
using System.Collections;
using System.Reflection;
using Sedulous.Engine.Core;

namespace Sedulous.Editor.Core;

/// Command to set a component attribute value via reflection.
public class SetAttributeCommand : IEditorCommand
{
	private Component mComponent;
	private String mFieldName ~ delete _;
	private Variant mOldValue ~ _.Dispose();
	private Variant mNewValue ~ _.Dispose();

	public this(Component component, StringView fieldName, Variant oldValue, Variant newValue)
	{
		mComponent = component;
		mFieldName = new String(fieldName);
		mOldValue = oldValue;
		mNewValue = newValue;
	}

	public void GetDescription(String outStr)
	{
		outStr.AppendF("Set {}", mFieldName);
	}

	public void Execute()
	{
		SetField(mNewValue);
	}

	public void Undo()
	{
		SetField(mOldValue);
	}

	private void SetField(Variant value)
	{
		if (mComponent == null)
			return;

		let type = mComponent.GetType();
		for (let field in type.GetFields(.Instance | .NonPublic | .Public))
		{
			let sourceName = scope String();
			field.GetSourceName(sourceName);

			if (sourceName.Equals(mFieldName, .OrdinalIgnoreCase))
			{
				field.SetValue(mComponent, value);
				break;
			}
		}
	}
}

/// Command to create a child node.
public class CreateNodeCommand : IEditorCommand
{
	private Node mParent;
	private Node mCreatedNode;
	private String mName ~ delete _;

	public this(Node parent, StringView name = "Node")
	{
		mParent = parent;
		mName = new String(name);
	}

	/// The node that was created (available after Execute).
	public Node CreatedNode => mCreatedNode;

	public void GetDescription(String outStr)
	{
		outStr.AppendF("Create Node '{}'", mName);
	}

	public void Execute()
	{
		if (mParent == null)
			return;

		mCreatedNode = mParent.CreateChild();
		mCreatedNode.SetName(mName);
	}

	public void Undo()
	{
		if (mCreatedNode != null && mParent != null)
		{
			mParent.RemoveChild(mCreatedNode);
			mCreatedNode = null;
		}
	}
}

/// Command to delete a node.
public class DeleteNodeCommand : IEditorCommand
{
	private Node mParent;
	private Node mNode;
	private String mNodeName ~ delete _;
	private bool mDeleted = false;

	public this(Node node)
	{
		mNode = node;
		mParent = node?.Parent;
		mNodeName = new String(node?.Name ?? "");
	}

	public void GetDescription(String outStr)
	{
		outStr.AppendF("Delete Node '{}'", mNodeName);
	}

	public void Execute()
	{
		if (mNode != null && mParent != null)
		{
			mParent.RemoveChild(mNode);
			mDeleted = true;
		}
	}

	public void Undo()
	{
		if (mDeleted && mNode != null && mParent != null)
		{
			mParent.AddChild(mNode);
			mDeleted = false;
		}
	}
}

/// Command to create a component on a node.
public class CreateComponentCommand : IEditorCommand
{
	private Node mNode;
	private Component mComponent;
	private String mTypeName ~ delete _;
	private Context mContext;

	public this(Node node, StringView typeName, Context context)
	{
		mNode = node;
		mTypeName = new String(typeName);
		mContext = context;
	}

	/// The component that was created (available after Execute).
	public Component CreatedComponent => mComponent;

	public void GetDescription(String outStr)
	{
		outStr.AppendF("Add Component '{}'", mTypeName);
	}

	public void Execute()
	{
		if (mNode == null || mContext == null)
			return;

		let obj = mContext.CreateComponent(mTypeName);
		if (obj == null)
			return;

		mComponent = obj as Component;
		if (mComponent == null)
		{
			delete obj;
			return;
		}

		mNode.AddComponent(mComponent);
	}

	public void Undo()
	{
		if (mComponent != null && mNode != null)
		{
			mNode.RemoveComponent(mComponent);
			mComponent = null;
		}
	}
}

/// Command to delete a component from a node.
public class DeleteComponentCommand : IEditorCommand
{
	private Node mNode;
	private Component mComponent;
	private String mTypeName ~ delete _;
	private bool mDeleted = false;

	public this(Component component)
	{
		mComponent = component;
		mNode = component?.Node;

		mTypeName = new .();
		if (component != null)
			component.GetType().GetName(mTypeName);
	}

	public void GetDescription(String outStr)
	{
		outStr.AppendF("Delete Component '{}'", mTypeName);
	}

	public void Execute()
	{
		if (mComponent != null && mNode != null)
		{
			mNode.RemoveComponent(mComponent);
			mDeleted = true;
		}
	}

	public void Undo()
	{
		if (mDeleted && mComponent != null && mNode != null)
		{
			mNode.AddComponent(mComponent);
			mDeleted = false;
		}
	}
}

/// Command to rename a node.
public class RenameNodeCommand : IEditorCommand
{
	private Node mNode;
	private String mOldName ~ delete _;
	private String mNewName ~ delete _;

	public this(Node node, StringView newName)
	{
		mNode = node;
		mOldName = new String(node?.Name ?? "");
		mNewName = new String(newName);
	}

	public void GetDescription(String outStr)
	{
		outStr.AppendF("Rename '{}' → '{}'", mOldName, mNewName);
	}

	public void Execute()
	{
		if (mNode != null)
			mNode.SetName(mNewName);
	}

	public void Undo()
	{
		if (mNode != null)
			mNode.SetName(mOldName);
	}
}
