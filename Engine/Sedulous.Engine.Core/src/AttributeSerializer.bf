using System;
using System.Collections;
using System.Reflection;
using Sedulous.Foundation.Mathematics;

namespace Sedulous.Engine.Core;

/// Serialized attribute value: field name → variant value.
public struct AttributeValue
{
	public String Name;
	public Variant Value;

	public this(String name, Variant value)
	{
		Name = name;
		Value = value;
	}
}

/// Reflection-based serializer that reads/writes component fields marked with [Editable].
///
/// Uses Beef's runtime reflection to iterate fields, check for [Editable]/[Transient]
/// attributes, and get/set values via Variant. This enables automatic scene serialization
/// without manual attribute registration (like Urho3D's URHO3D_ATTRIBUTE macros).
///
public static class AttributeSerializer
{
	/// Collects all serializable field values from a component.
	/// Only fields marked [Editable] and not [Transient] are included.
	/// Returns owned AttributeValue entries — caller must dispose Names and Variants.
	public static void GetAttributes(Component component, List<AttributeValue> outAttributes)
	{
		if (component == null)
			return;

		let type = component.GetType();
		for (let field in type.GetFields(.Instance | .NonPublic | .Public))
		{
			// Skip transient fields
			if (field.HasCustomAttribute<TransientAttribute>())
				continue;

			// Only serialize editable fields
			if (!field.HasCustomAttribute<EditableAttribute>())
				continue;

			// Get display name
			String displayName = new .();
			if (field.GetCustomAttribute<EditableAttribute>() case .Ok(let attr))
			{
				if (attr.DisplayName != null)
					displayName.Set(attr.DisplayName);
				else
					field.GetSourceName(displayName);
			}
			else
			{
				field.GetSourceName(displayName);
			}

			// Get value as Variant
			if (field.GetValue(component) case .Ok(let variant))
			{
				outAttributes.Add(.(displayName, variant));
			}
			else
			{
				delete displayName;
			}
		}
	}

	/// Applies serialized attribute values to a component.
	/// Matches by field source name or display name.
	public static void SetAttributes(Component component, Span<AttributeValue> attributes)
	{
		if (component == null)
			return;

		let type = component.GetType();
		for (let field in type.GetFields(.Instance | .NonPublic | .Public))
		{
			if (field.HasCustomAttribute<TransientAttribute>())
				continue;
			if (!field.HasCustomAttribute<EditableAttribute>())
				continue;

			// Get both source name and display name for matching
			String sourceName = scope .();
			field.GetSourceName(sourceName);

			String displayName = scope .();
			if (field.GetCustomAttribute<EditableAttribute>() case .Ok(let attr))
			{
				if (attr.DisplayName != null)
					displayName.Set(attr.DisplayName);
				else
					displayName.Set(sourceName);
			}
			else
			{
				displayName.Set(sourceName);
			}

			// Find matching attribute value
			for (let attrVal in attributes)
			{
				if (attrVal.Name.Equals(sourceName, .OrdinalIgnoreCase) ||
					attrVal.Name.Equals(displayName, .OrdinalIgnoreCase))
				{
					field.SetValue(component, attrVal.Value);
					break;
				}
			}
		}
	}

	/// Gets the list of editable field descriptors for a component type.
	/// Useful for editor UI generation.
	public static void GetEditableFields(Type type, List<EditableFieldInfo> outFields)
	{
		let typeInstance = type as TypeInstance;
		if (typeInstance == null)
			return;

		for (let field in typeInstance.GetFields(.Instance | .NonPublic | .Public))
		{
			if (field.HasCustomAttribute<TransientAttribute>())
				continue;
			if (!field.HasCustomAttribute<EditableAttribute>())
				continue;

			EditableFieldInfo info = .();
			info.FieldName = new .();
			field.GetSourceName(info.FieldName);

			info.DisplayName = new .();
			if (field.GetCustomAttribute<EditableAttribute>() case .Ok(let attr))
			{
				if (attr.DisplayName != null)
					info.DisplayName.Set(attr.DisplayName);
				else
					info.DisplayName.Set(info.FieldName);
			}
			else
			{
				info.DisplayName.Set(info.FieldName);
			}

			info.FieldType = field.FieldType;

			if (field.GetCustomAttribute<RangeAttribute>() case .Ok(let rangeAttr))
			{
				info.HasRange = true;
				info.RangeMin = rangeAttr.Min;
				info.RangeMax = rangeAttr.Max;
				info.RangeStep = rangeAttr.Step;
			}

			outFields.Add(info);
		}
	}

	/// Writes a Variant value to a string representation.
	public static void VariantToString(Variant value, String outStr)
	{
		let type = value.VariantType;

		if (type == typeof(bool))
			outStr.AppendF("{}", value.Get<bool>());
		else if (type == typeof(int32))
			outStr.AppendF("{}", value.Get<int32>());
		else if (type == typeof(int64))
			outStr.AppendF("{}", value.Get<int64>());
		else if (type == typeof(uint32))
			outStr.AppendF("{}", value.Get<uint32>());
		else if (type == typeof(float))
			outStr.AppendF("{}", value.Get<float>());
		else if (type == typeof(double))
			outStr.AppendF("{}", value.Get<double>());
		else if (type == typeof(Vector2))
		{
			let v = value.Get<Vector2>();
			outStr.AppendF("{} {}", v.X, v.Y);
		}
		else if (type == typeof(Vector3))
		{
			let v = value.Get<Vector3>();
			outStr.AppendF("{} {} {}", v.X, v.Y, v.Z);
		}
		else if (type == typeof(Vector4))
		{
			let v = value.Get<Vector4>();
			outStr.AppendF("{} {} {} {}", v.X, v.Y, v.Z, v.W);
		}
		else if (type == typeof(Quaternion))
		{
			let q = value.Get<Quaternion>();
			outStr.AppendF("{} {} {} {}", q.X, q.Y, q.Z, q.W);
		}
		else if (type == typeof(Color))
		{
			let c = value.Get<Color>();
			outStr.AppendF("{}", c.PackedValue);
		}
		else if (type.IsEnum)
		{
			// Write enum as integer
			outStr.AppendF("{}", value.Get<int32>());
		}
		else if (type == typeof(String))
		{
			let obj = value.Get<Object>();
			if (obj != null)
				outStr.Append(obj as String);
		}
		else
		{
			outStr.Append("?");
		}
	}

	/// Parses a string into a Variant of the given type.
	public static Result<Variant> StringToVariant(StringView str, Type type)
	{
		if (type == typeof(bool))
		{
			if (bool.Parse(str) case .Ok(let v))
				return Variant.Create<bool>(v);
		}
		else if (type == typeof(int32))
		{
			if (int32.Parse(str) case .Ok(let v))
				return Variant.Create<int32>(v);
		}
		else if (type == typeof(int64))
		{
			if (int64.Parse(str) case .Ok(let v))
				return Variant.Create<int64>(v);
		}
		else if (type == typeof(uint32))
		{
			if (uint32.Parse(str) case .Ok(let v))
				return Variant.Create<uint32>(v);
		}
		else if (type == typeof(float))
		{
			if (float.Parse(str) case .Ok(let v))
				return Variant.Create<float>(v);
		}
		else if (type == typeof(double))
		{
			if (double.Parse(str) case .Ok(let v))
				return Variant.Create<double>(v);
		}
		else if (type == typeof(Vector2))
		{
			if (ParseVector2(str) case .Ok(let v))
				return Variant.Create<Vector2>(v);
		}
		else if (type == typeof(Vector3))
		{
			if (ParseVector3(str) case .Ok(let v))
				return Variant.Create<Vector3>(v);
		}
		else if (type == typeof(Vector4))
		{
			if (ParseVector4(str) case .Ok(let v))
				return Variant.Create<Vector4>(v);
		}
		else if (type == typeof(Quaternion))
		{
			if (ParseQuaternion(str) case .Ok(let v))
				return Variant.Create<Quaternion>(v);
		}
		else if (type == typeof(Color))
		{
			if (uint32.Parse(str) case .Ok(let v))
				return Variant.Create<Color>(Color(v));
		}
		else if (type.IsEnum)
		{
			if (int32.Parse(str) case .Ok(var v))
				return Variant.Create(type, &v);
		}

		return .Err;
	}

	// ===== Private Parsers =====

	private static Result<Vector2> ParseVector2(StringView str)
	{
		var enumerator = str.Split(' ');
		float x = 0, y = 0;
		if (enumerator.GetNext() case .Ok(let sx)) { if (float.Parse(sx) case .Ok(let v)) x = v; else return .Err; } else return .Err;
		if (enumerator.GetNext() case .Ok(let sy)) { if (float.Parse(sy) case .Ok(let v)) y = v; else return .Err; } else return .Err;
		return Vector2(x, y);
	}

	private static Result<Vector3> ParseVector3(StringView str)
	{
		var enumerator = str.Split(' ');
		float x = 0, y = 0, z = 0;
		if (enumerator.GetNext() case .Ok(let sx)) { if (float.Parse(sx) case .Ok(let v)) x = v; else return .Err; } else return .Err;
		if (enumerator.GetNext() case .Ok(let sy)) { if (float.Parse(sy) case .Ok(let v)) y = v; else return .Err; } else return .Err;
		if (enumerator.GetNext() case .Ok(let sz)) { if (float.Parse(sz) case .Ok(let v)) z = v; else return .Err; } else return .Err;
		return Vector3(x, y, z);
	}

	private static Result<Vector4> ParseVector4(StringView str)
	{
		var enumerator = str.Split(' ');
		float x = 0, y = 0, z = 0, w = 0;
		if (enumerator.GetNext() case .Ok(let sx)) { if (float.Parse(sx) case .Ok(let v)) x = v; else return .Err; } else return .Err;
		if (enumerator.GetNext() case .Ok(let sy)) { if (float.Parse(sy) case .Ok(let v)) y = v; else return .Err; } else return .Err;
		if (enumerator.GetNext() case .Ok(let sz)) { if (float.Parse(sz) case .Ok(let v)) z = v; else return .Err; } else return .Err;
		if (enumerator.GetNext() case .Ok(let sw)) { if (float.Parse(sw) case .Ok(let v)) w = v; else return .Err; } else return .Err;
		return Vector4(x, y, z, w);
	}

	private static Result<Quaternion> ParseQuaternion(StringView str)
	{
		if (ParseVector4(str) case .Ok(let v))
			return Quaternion(v.X, v.Y, v.Z, v.W);
		return .Err;
	}
}

/// Descriptor for an editable field, used by editor/inspector UI.
public struct EditableFieldInfo : IDisposable
{
	public String FieldName;
	public String DisplayName;
	public Type FieldType;
	public bool HasRange;
	public float RangeMin;
	public float RangeMax;
	public float RangeStep;

	public void Dispose()
	{
		delete FieldName;
		delete DisplayName;
	}
}
