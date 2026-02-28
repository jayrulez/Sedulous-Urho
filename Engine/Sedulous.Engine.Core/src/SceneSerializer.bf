using System;
using System.Collections;
using System.Reflection;
using Sedulous.Foundation.Mathematics;
using Sedulous.Xml;

namespace Sedulous.Engine.Core;

using internal Sedulous.Engine.Core;

/// Serializes and deserializes scene hierarchies to/from XML.
///
/// The XML format follows Urho3D's scene file structure:
///   <scene>
///     <node name="..." enabled="true">
///       <position>x y z</position>
///       <rotation>x y z w</rotation>
///       <scale>x y z</scale>
///       <tags>tag1 tag2</tags>
///       <component type="StaticModel">
///         <attribute name="..." value="..." />
///       </component>
///       <node> ... </node>  <!-- children -->
///     </node>
///   </scene>
///
public static class SceneSerializer
{
	/// Saves an entire scene to XML string.
	public static void SaveScene(Scene scene, String outXml)
	{
		let doc = scope XmlDocument();
		let root = doc.CreateElement("scene");

		// Scene-level attributes
		root.SetAttribute("timeScale", scope String()..AppendF("{}", scene.TimeScale));
		root.SetAttribute("elapsedTime", scope String()..AppendF("{}", scene.ElapsedTime));

		// Serialize scene-level components
		for (let component in scene.Components)
		{
			let compElem = doc.CreateElement("component");
			SerializeComponent(doc, compElem, component);
			root.AppendChild(compElem);
		}

		// Serialize child nodes (depth-first)
		for (let child in scene.Children)
		{
			let nodeElem = doc.CreateElement("node");
			SerializeNode(doc, nodeElem, child);
			root.AppendChild(nodeElem);
		}

		doc.AppendChild(root);
		doc.WriteTo(outXml);
	}

	/// Loads a scene from XML string into an existing scene.
	/// Clears the scene first.
	public static Result<void> LoadScene(Scene scene, StringView xml, Context context)
	{
		let doc = scope XmlDocument();
		if (doc.Parse(xml).IsError)
			return .Err;

		let root = doc.RootElement;
		if (root == null)
			return .Err;

		// Clear existing scene content
		scene.DestroyAllChildren();

		// Load scene-level attributes
		let timeScaleStr = root.GetAttribute("timeScale");
		if (!timeScaleStr.IsEmpty)
		{
			if (float.Parse(timeScaleStr) case .Ok(let v))
				scene.TimeScale = v;
		}

		// Load scene-level components
		let compElems = scope List<XmlElement>();
		root.GetChildElements("component", compElems);
		for (let compElem in compElems)
		{
			DeserializeComponent(compElem, scene, context);
		}

		// Load child nodes
		let nodeElems = scope List<XmlElement>();
		root.GetChildElements("node", nodeElems);
		for (let nodeElem in nodeElems)
		{
			let child = scene.CreateChild();
			DeserializeNode(nodeElem, child, context);
		}

		return .Ok;
	}

	/// Saves a single node subtree to XML (for prefabs).
	public static void SaveNode(Node node, String outXml)
	{
		let doc = scope XmlDocument();
		let nodeElem = doc.CreateElement("node");
		SerializeNode(doc, nodeElem, node);
		doc.AppendChild(nodeElem);
		doc.WriteTo(outXml);
	}

	/// Loads a node subtree from XML and attaches it to the given parent.
	public static Result<Node> LoadNode(Node parent, StringView xml, Context context)
	{
		let doc = scope XmlDocument();
		if (doc.Parse(xml).IsError)
			return .Err;

		let nodeElem = doc.RootElement;
		if (nodeElem == null)
			return .Err;

		let node = parent.CreateChild();
		DeserializeNode(nodeElem, node, context);
		return node;
	}

	// ===== Private: Serialization =====

	private static void SerializeNode(XmlDocument doc, XmlElement elem, Node node)
	{
		// Node attributes
		elem.SetAttribute("name", node.Name);
		if (!node.Enabled)
			elem.SetAttribute("enabled", "false");

		// Transform
		let pos = node.Position;
		let rot = node.Rotation;
		let scale = node.Scale;

		let posElem = doc.CreateElement("position");
		posElem.SetTextContent(scope String()..AppendF("{} {} {}", pos.X, pos.Y, pos.Z));
		elem.AppendChild(posElem);

		let rotElem = doc.CreateElement("rotation");
		rotElem.SetTextContent(scope String()..AppendF("{} {} {} {}", rot.X, rot.Y, rot.Z, rot.W));
		elem.AppendChild(rotElem);

		if (scale != Vector3.One)
		{
			let scaleElem = doc.CreateElement("scale");
			scaleElem.SetTextContent(scope String()..AppendF("{} {} {}", scale.X, scale.Y, scale.Z));
			elem.AppendChild(scaleElem);
		}

		// Tags
		if (node.[Friend]mTags.Count > 0)
		{
			let tagsElem = doc.CreateElement("tags");
			let tagsStr = scope String();
			bool first = true;
			for (let tag in node.[Friend]mTags)
			{
				if (!first) tagsStr.Append(' ');
				tagsStr.Append(tag);
				first = false;
			}
			tagsElem.SetTextContent(tagsStr);
			elem.AppendChild(tagsElem);
		}

		// Components
		for (let component in node.Components)
		{
			let compElem = doc.CreateElement("component");
			SerializeComponent(doc, compElem, component);
			elem.AppendChild(compElem);
		}

		// Children (recursive)
		for (let child in node.Children)
		{
			let childElem = doc.CreateElement("node");
			SerializeNode(doc, childElem, child);
			elem.AppendChild(childElem);
		}
	}

	private static void SerializeComponent(XmlDocument doc, XmlElement elem, Component component)
	{
		// Write type name
		let typeName = scope String();
		component.GetType().GetName(typeName);
		elem.SetAttribute("type", typeName);

		// Write editable fields
		let attributes = scope List<AttributeValue>();
		AttributeSerializer.GetAttributes(component, attributes);

		for (let attr in attributes)
		{
			let attrElem = doc.CreateElement("attribute");
			attrElem.SetAttribute("name", attr.Name);

			let valueStr = scope String();
			AttributeSerializer.VariantToString(attr.Value, valueStr);
			attrElem.SetAttribute("value", valueStr);

			elem.AppendChild(attrElem);
		}

		// Clean up
		for (var attr in attributes)
		{
			delete attr.Name;
			attr.Value.Dispose();
		}
	}

	// ===== Private: Deserialization =====

	private static void DeserializeNode(XmlElement elem, Node node, Context context)
	{
		// Name
		let name = elem.GetAttribute("name");
		if (!name.IsEmpty)
			node.SetName(name);

		// Enabled
		let enabledStr = elem.GetAttribute("enabled");
		if (enabledStr == "false")
			node.Enabled = false;

		// Position
		let posElems = scope List<XmlElement>();
		elem.GetChildElements("position", posElems);
		if (posElems.Count > 0)
		{
			let text = scope String();
			posElems[0].GetTextContent(text);
			if (ParseVector3(text) case .Ok(let pos))
				node.Position = pos;
		}

		// Rotation
		let rotElems = scope List<XmlElement>();
		elem.GetChildElements("rotation", rotElems);
		if (rotElems.Count > 0)
		{
			let text = scope String();
			rotElems[0].GetTextContent(text);
			if (ParseQuaternion(text) case .Ok(let rot))
				node.Rotation = rot;
		}

		// Scale
		let scaleElems = scope List<XmlElement>();
		elem.GetChildElements("scale", scaleElems);
		if (scaleElems.Count > 0)
		{
			let text = scope String();
			scaleElems[0].GetTextContent(text);
			if (ParseVector3(text) case .Ok(let scale))
				node.Scale = scale;
		}

		// Tags
		let tagElems = scope List<XmlElement>();
		elem.GetChildElements("tags", tagElems);
		if (tagElems.Count > 0)
		{
			let text = scope String();
			tagElems[0].GetTextContent(text);
			for (let tag in text.Split(' '))
			{
				if (!tag.IsEmpty)
					node.AddTag(tag);
			}
		}

		// Components
		let compElems = scope List<XmlElement>();
		elem.GetChildElements("component", compElems);
		for (let compElem in compElems)
		{
			DeserializeComponent(compElem, node, context);
		}

		// Children
		let childElems = scope List<XmlElement>();
		elem.GetChildElements("node", childElems);
		for (let childElem in childElems)
		{
			let child = node.CreateChild();
			DeserializeNode(childElem, child, context);
		}
	}

	private static void DeserializeComponent(XmlElement elem, Node node, Context context)
	{
		let typeName = elem.GetAttribute("type");
		if (typeName.IsEmpty)
			return;

		// Create component via factory
		let obj = context.CreateComponent(typeName);
		if (obj == null)
			return;

		let component = obj as Component;
		if (component == null)
		{
			delete obj;
			return;
		}

		// Read attributes
		let attrElems = scope List<XmlElement>();
		elem.GetChildElements("attribute", attrElems);

		let attrValues = scope List<AttributeValue>();
		for (let attrElem in attrElems)
		{
			let name = attrElem.GetAttribute("name");
			let valueStr = attrElem.GetAttribute("value");
			if (name.IsEmpty)
				continue;

			// We need the field type to parse — find it from the component's type
			let fieldType = FindFieldType(component.GetType(), name);
			if (fieldType != null)
			{
				if (AttributeSerializer.StringToVariant(valueStr, fieldType) case .Ok(let variant))
				{
					attrValues.Add(.(new String(name), variant));
				}
			}
		}

		// Apply attributes
		AttributeSerializer.SetAttributes(component, attrValues);

		// Clean up
		for (var av in attrValues)
		{
			delete av.Name;
			av.Value.Dispose();
		}

		// Attach to node
		node.AddComponent(component);
	}

	/// Finds the type of an [Editable] field by display name or source name.
	private static Type FindFieldType(Type type, StringView name)
	{
		let typeInstance = type as TypeInstance;
		if (typeInstance == null)
			return null;

		for (let field in typeInstance.GetFields(.Instance | .NonPublic | .Public))
		{
			if (!field.HasCustomAttribute<EditableAttribute>())
				continue;

			let sourceName = scope String();
			field.GetSourceName(sourceName);

			if (sourceName.Equals(name, .OrdinalIgnoreCase))
				return field.FieldType;

			if (field.GetCustomAttribute<EditableAttribute>() case .Ok(let attr))
			{
				if (attr.DisplayName != null && StringView(attr.DisplayName).Equals(name, true))
					return field.FieldType;
			}
		}

		return null;
	}

	// ===== Private: Parsers =====

	private static Result<Vector3> ParseVector3(StringView str)
	{
		var iter = str.Split(' ');
		float x = 0, y = 0, z = 0;
		if (iter.GetNext() case .Ok(let sx)) { if (float.Parse(sx) case .Ok(let v)) x = v; else return .Err; } else return .Err;
		if (iter.GetNext() case .Ok(let sy)) { if (float.Parse(sy) case .Ok(let v)) y = v; else return .Err; } else return .Err;
		if (iter.GetNext() case .Ok(let sz)) { if (float.Parse(sz) case .Ok(let v)) z = v; else return .Err; } else return .Err;
		return Vector3(x, y, z);
	}

	private static Result<Quaternion> ParseQuaternion(StringView str)
	{
		var iter = str.Split(' ');
		float x = 0, y = 0, z = 0, w = 0;
		if (iter.GetNext() case .Ok(let sx)) { if (float.Parse(sx) case .Ok(let v)) x = v; else return .Err; } else return .Err;
		if (iter.GetNext() case .Ok(let sy)) { if (float.Parse(sy) case .Ok(let v)) y = v; else return .Err; } else return .Err;
		if (iter.GetNext() case .Ok(let sz)) { if (float.Parse(sz) case .Ok(let v)) z = v; else return .Err; } else return .Err;
		if (iter.GetNext() case .Ok(let sw)) { if (float.Parse(sw) case .Ok(let v)) w = v; else return .Err; } else return .Err;
		return Quaternion(x, y, z, w);
	}
}
