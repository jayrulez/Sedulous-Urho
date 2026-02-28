using System;
using System.Collections;
using System.Reflection;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using Sedulous.GUI;

namespace Sedulous.Editor.Core;

/// Tracks the mapping between a PropertyItem and the component field it edits.
class FieldBinding
{
	public Component Component;
	public String FieldName ~ delete _;
	public Type FieldType;
	/// Last known field value (for undo). Ownership managed by TakeOldValue/SetOldValue.
	public Variant OldValue;
	public bool HasOldValue = false;

	public void SetOldValue(Variant v)
	{
		if (HasOldValue)
			OldValue.Dispose();
		OldValue = v;
		HasOldValue = true;
	}

	/// Transfers ownership of the old value to the caller. Binding no longer owns it.
	public Variant TakeOldValue()
	{
		let v = OldValue;
		OldValue = default;
		HasOldValue = false;
		return v;
	}

	public ~this()
	{
		if (HasOldValue)
			OldValue.Dispose();
	}
}

/// Editor panel that inspects and edits the selected node's component properties.
///
/// Uses AttributeSerializer reflection to discover [Editable] fields on each
/// component and populates a PropertyGrid. Edits go through the undo/redo system.
///
public class InspectorPanel
{
	private EditorState mEditor;
	private StackPanel mPanel ~ delete _;
	private PropertyGrid mPropertyGrid;
	private TextBlock mHeader;
	private Node mCurrentNode;
	private List<FieldBinding> mBindings = new .() ~ DeleteContainerAndItems!(_);
	private Dictionary<PropertyItem, FieldBinding> mPropertyMap = new .() ~ delete _;

	public this(EditorState editor)
	{
		mEditor = editor;
		BuildUI();
		editor.Selection.OnSelectionChanged.Add(new => OnSelectionChanged);
	}

	/// The root UI element for this panel.
	public StackPanel RootElement => mPanel;

	// ===== UI Construction =====

	private void BuildUI()
	{
		mPanel = new StackPanel();
		mPanel.Orientation = .Vertical;

		mHeader = new TextBlock();
		mHeader.Text = "Inspector";
		mPanel.AddChild(mHeader);

		mPropertyGrid = new PropertyGrid();
		mPropertyGrid.PropertyChanged.Subscribe(new => OnPropertyChanged);
		mPanel.AddChild(mPropertyGrid);
	}

	// ===== Rebuild =====

	/// Rebuilds the inspector for the currently selected node.
	public void RebuildInspector()
	{
		mPropertyGrid.Clear();
		mPropertyMap.Clear();
		DeleteContainerAndItems!(mBindings);
		mBindings = new .();

		let node = mEditor.Selection.PrimaryNode;
		mCurrentNode = node;

		if (node == null)
		{
			mHeader.Text = "Inspector";
			return;
		}

		let name = node.Name.IsEmpty ? "(unnamed)" : node.Name;
		mHeader.Text = scope $"Inspector - {name}";

		mPropertyGrid.BeginUpdate();

		for (let component in node.Components)
			AddComponentProperties(component);

		mPropertyGrid.EndUpdate();
	}

	/// Refreshes all property display values from their current field values.
	public void RefreshValues()
	{
		mPropertyGrid.RefreshValues();
	}

	// ===== Property Generation =====

	private void AddComponentProperties(Component component)
	{
		let type = component.GetType();
		let typeName = scope String();
		type.GetName(typeName);

		var fields = scope List<EditableFieldInfo>();
		AttributeSerializer.GetEditableFields(type, fields);

		for (var fieldInfo in ref fields)
		{
			// Create binding
			let binding = new FieldBinding();
			binding.Component = component;
			binding.FieldName = new String(fieldInfo.FieldName);
			binding.FieldType = fieldInfo.FieldType;

			// Store initial value for undo
			if (ReadFieldVariant(component, fieldInfo.FieldName) case .Ok(let v))
				binding.SetOldValue(v);

			mBindings.Add(binding);

			// Determine property type
			let propType = MapFieldType(fieldInfo.FieldType);
			let displayName = fieldInfo.DisplayName;
			let comp = component;
			let fname = binding.FieldName;

			PropertyItem prop = null;
			switch (propType)
			{
			case .Bool:
				prop = mPropertyGrid.AddBoolProperty(displayName, typeName,
					new () => ReadBoolBoxed(comp, fname),
					new (val) => WriteBoolBoxed(comp, fname, val));
			case .Int:
				prop = mPropertyGrid.AddIntProperty(displayName, typeName,
					new () => ReadIntBoxed(comp, fname),
					new (val) => WriteIntBoxed(comp, fname, val));
			case .Float:
				prop = mPropertyGrid.AddFloatProperty(displayName, typeName,
					new () => ReadFloatBoxed(comp, fname),
					new (val) => WriteFloatBoxed(comp, fname, val));
			case .Enum:
				let enumOptions = GetEnumOptions(fieldInfo.FieldType);
				prop = mPropertyGrid.AddEnumProperty(displayName, typeName, enumOptions,
					new () => ReadEnumBoxed(comp, fname),
					new (val) => WriteEnumBoxed(comp, fname, fieldInfo.FieldType, val));
			default:
				prop = mPropertyGrid.AddStringProperty(displayName, typeName,
					new () => ReadStringBoxed(comp, fname),
					new (val) => WriteStringBoxed(comp, fname, fieldInfo.FieldType, val));
			}

			if (prop != null)
				mPropertyMap[prop] = binding;

			// Cleanup — property grid owns the display name string via PropertyItem
			fieldInfo.FieldName = null;
			fieldInfo.DisplayName = null;
		}
	}

	// ===== Property Changed → Undo/Redo =====

	private void OnPropertyChanged(PropertyGrid grid, PropertyItem item)
	{
		if (!mPropertyMap.TryGetValue(item, var binding))
			return;

		// Take the old value from binding (transfers ownership to us → command)
		let oldValue = binding.TakeOldValue();

		// Read the current (new) value for the command
		Variant newValue = default;
		if (ReadFieldVariant(binding.Component, binding.FieldName) case .Ok(let v))
			newValue = v;

		// Create undo command — Execute is redundant (setter already applied) but harmless
		let cmd = new SetAttributeCommand(binding.Component, binding.FieldName, oldValue, newValue);
		mEditor.ExecuteCommand(cmd);

		// Read field again for the binding's new "old" value
		if (ReadFieldVariant(binding.Component, binding.FieldName) case .Ok(let v2))
			binding.SetOldValue(v2);
	}

	private void OnSelectionChanged()
	{
		RebuildInspector();
	}

	// ===== Field Type Mapping =====

	private static PropertyType MapFieldType(Type fieldType)
	{
		if (fieldType == typeof(bool))
			return .Bool;
		if (fieldType == typeof(int32) || fieldType == typeof(int64) || fieldType == typeof(uint32))
			return .Int;
		if (fieldType == typeof(float) || fieldType == typeof(double))
			return .Float;
		if (fieldType == typeof(Color))
			return .Color;
		if (fieldType.IsEnum)
			return .Enum;
		return .String;
	}

	private static Span<StringView> GetEnumOptions(Type enumType)
	{
		// For now, return empty span — enum names would require deeper reflection
		return .();
	}

	// ===== Reflection Helpers =====

	private static Result<Variant> ReadFieldVariant(Component component, StringView fieldName)
	{
		let type = component.GetType();
		for (let field in type.GetFields(.Instance | .NonPublic | .Public))
		{
			let sname = scope String();
			field.GetSourceName(sname);
			if (sname == fieldName)
				return field.GetValue(component);
		}
		return .Err;
	}

	private static void WriteFieldVariant(Component component, StringView fieldName, Variant value)
	{
		let type = component.GetType();
		for (let field in type.GetFields(.Instance | .NonPublic | .Public))
		{
			let sname = scope String();
			field.GetSourceName(sname);
			if (sname == fieldName)
			{
				field.SetValue(component, value);
				break;
			}
		}
	}

	// ===== Boxed Getter/Setter Helpers =====

	private static Object ReadBoolBoxed(Component comp, String fieldName)
	{
		if (ReadFieldVariant(comp, fieldName) case .Ok(var v))
		{
			let val = v.Get<bool>();
			v.Dispose();
			return new box val;
		}
		return new box false;
	}

	private static void WriteBoolBoxed(Component comp, String fieldName, Object val)
	{
		if (let b = val as bool?)
		{
			var variant = Variant.Create<bool>(b);
			WriteFieldVariant(comp, fieldName, variant);
			variant.Dispose();
		}
	}

	private static Object ReadIntBoxed(Component comp, String fieldName)
	{
		if (ReadFieldVariant(comp, fieldName) case .Ok(var v))
		{
			let vtype = v.VariantType;
			int result = 0;
			if (vtype == typeof(int32))
				result = v.Get<int32>();
			else if (vtype == typeof(int64))
				result = (.)v.Get<int64>();
			else if (vtype == typeof(uint32))
				result = (.)v.Get<uint32>();
			v.Dispose();
			return new box result;
		}
		return new box (int)0;
	}

	private static void WriteIntBoxed(Component comp, String fieldName, Object val)
	{
		if (ReadFieldVariant(comp, fieldName) case .Ok(var current))
		{
			let vtype = current.VariantType;
			current.Dispose();

			if (let num = val as int?)
			{
				Variant variant = default;
				if (vtype == typeof(int32))
					variant = Variant.Create<int32>((.)num);
				else if (vtype == typeof(int64))
					variant = Variant.Create<int64>((.)num);
				else if (vtype == typeof(uint32))
					variant = Variant.Create<uint32>((.)num);
				else
					variant = Variant.Create<int32>((.)num);
				WriteFieldVariant(comp, fieldName, variant);
				variant.Dispose();
			}
		}
	}

	private static Object ReadFloatBoxed(Component comp, String fieldName)
	{
		if (ReadFieldVariant(comp, fieldName) case .Ok(var v))
		{
			float result = 0;
			if (v.VariantType == typeof(float))
				result = v.Get<float>();
			else if (v.VariantType == typeof(double))
				result = (.)v.Get<double>();
			v.Dispose();
			return new box result;
		}
		return new box 0.0f;
	}

	private static void WriteFloatBoxed(Component comp, String fieldName, Object val)
	{
		if (let num = val as float?)
		{
			if (ReadFieldVariant(comp, fieldName) case .Ok(var current))
			{
				let vtype = current.VariantType;
				current.Dispose();

				Variant variant = default;
				if (vtype == typeof(double))
					variant = Variant.Create<double>((.)num);
				else
					variant = Variant.Create<float>(num);
				WriteFieldVariant(comp, fieldName, variant);
				variant.Dispose();
			}
		}
	}

	private static Object ReadEnumBoxed(Component comp, String fieldName)
	{
		if (ReadFieldVariant(comp, fieldName) case .Ok(var v))
		{
			let str = new String();
			AttributeSerializer.VariantToString(v, str);
			v.Dispose();
			return str;
		}
		return new String("?");
	}

	private static void WriteEnumBoxed(Component comp, String fieldName, Type fieldType, Object val)
	{
		if (let str = val as String)
		{
			if (AttributeSerializer.StringToVariant(str, fieldType) case .Ok(var variant))
			{
				WriteFieldVariant(comp, fieldName, variant);
				variant.Dispose();
			}
		}
	}

	private static Object ReadStringBoxed(Component comp, String fieldName)
	{
		if (ReadFieldVariant(comp, fieldName) case .Ok(var v))
		{
			let str = new String();
			AttributeSerializer.VariantToString(v, str);
			v.Dispose();
			return str;
		}
		return new String("");
	}

	private static void WriteStringBoxed(Component comp, String fieldName, Type fieldType, Object val)
	{
		if (let str = val as String)
		{
			if (AttributeSerializer.StringToVariant(str, fieldType) case .Ok(var variant))
			{
				WriteFieldVariant(comp, fieldName, variant);
				variant.Dispose();
			}
		}
	}
}
