using System;

namespace Sedulous.Engine.Core;

/// Marks a class as a registerable engine component.
/// The component factory discovers these types at startup via Beef reflection
/// and enables runtime instantiation via Context.CreateComponent().
///
/// Usage:
///   [EngineComponent("Rendering")]
///   class StaticModel : Component { ... }
///
[AttributeUsage(.Class, .ReflectAttribute, ReflectUser=.NonStaticFields | .Methods, AlwaysIncludeUser = .AssumeInstantiated)]
public struct EngineComponentAttribute : Attribute
{
	/// Category for editor grouping (e.g. "Rendering", "Physics", "Audio").
	public String Category;

	public this(String category = "General")
	{
		Category = category;
	}
}

/// Marks a field as serializable and editable in the inspector.
/// Fields with this attribute are automatically serialized when saving scenes
/// and displayed in the editor inspector panel.
///
/// Usage:
///   [Editable("Cast Shadows")]
///   bool mCastShadows = true;
///
[AttributeUsage(.Field | .Property, .ReflectAttribute)]
public struct EditableAttribute : Attribute
{
	/// Display name shown in editor. If null, the field name is used.
	public String DisplayName;

	public this(String displayName = null)
	{
		DisplayName = displayName;
	}
}

/// Marks a field as transient — it will not be serialized.
/// Use this on fields that hold runtime-only state.
///
/// Usage:
///   [Transient]
///   int32 mCachedValue;
///
[AttributeUsage(.Field, .ReflectAttribute)]
public struct TransientAttribute : Attribute
{
}

/// Specifies a numeric range constraint for a field.
/// Used by the editor to show sliders and clamp values.
///
/// Usage:
///   [Editable, Range(0.0f, 1.0f)]
///   float mAlpha = 1.0f;
///
[AttributeUsage(.Field, .ReflectAttribute)]
public struct RangeAttribute : Attribute
{
	public float Min;
	public float Max;
	public float Step;

	public this(float min, float max, float step = 0.0f)
	{
		Min = min;
		Max = max;
		Step = step;
	}
}
