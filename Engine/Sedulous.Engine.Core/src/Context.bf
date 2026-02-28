using System;
using System.Collections;
using System.Reflection;
using System.Threading;
using Sedulous.Foundation.Logging.Abstractions;

namespace Sedulous.Engine.Core;

/// Component registration info discovered via reflection.
public class ComponentInfo
{
	public Type ComponentType;
	public String Category = new .() ~ delete _;
	public String TypeName = new .() ~ delete _;

	public ~this()
	{
	}
}

/// Central engine registry providing subsystem access and component factory.
///
/// The Context is the engine's nervous system. It holds:
/// - Subsystem registry: GetSubsystem<T>() / RegisterSubsystem()
/// - Component factory: CreateComponent() using Beef reflection
/// - Component info: metadata about registered component types
///
/// Usage:
///   context.RegisterSubsystem<IShell>(shell);
///   let shell = context.GetSubsystem<IShell>();
///   let component = context.CreateComponent("StaticModel");
///
public class Context
{
	private Dictionary<Type, Object> mSubsystems = new .() ~ delete _;
	private Dictionary<String, ComponentInfo> mComponentInfoByName = new .() ~ delete _;
	private List<ComponentInfo> mComponentInfoList = new .() ~ DeleteContainerAndItems!(_);
	private Monitor mSubsystemMonitor = new .() ~ delete _;
	private ILogger mLogger;

	/// Gets the logger for the engine context.
	public ILogger Logger => mLogger;

	public this(ILogger logger = null)
	{
		mLogger = logger;
	}

	public ~this()
	{
	}

	// ===== Subsystem Registry =====

	/// Registers a subsystem instance accessible by its interface type.
	/// The Context does NOT own the subsystem — the caller manages its lifetime.
	public void RegisterSubsystem<T>(T subsystem) where T : class
	{
		using (mSubsystemMonitor.Enter())
		{
			let type = typeof(T);
			if (mSubsystems.ContainsKey(type))
			{
				mLogger?.LogWarning("Subsystem '{}' already registered, replacing.", type.GetName(.. scope .()));
			}
			mSubsystems[type] = subsystem;
		}
	}

	/// Retrieves a registered subsystem by type.
	/// Returns null if not registered.
	public T GetSubsystem<T>() where T : class
	{
		using (mSubsystemMonitor.Enter())
		{
			if (mSubsystems.TryGetValue(typeof(T), let obj))
				return obj as T;
			return null;
		}
	}

	/// Removes a registered subsystem.
	public void RemoveSubsystem<T>() where T : class
	{
		using (mSubsystemMonitor.Enter())
		{
			mSubsystems.Remove(typeof(T));
		}
	}

	/// Returns true if a subsystem of the given type is registered.
	public bool HasSubsystem<T>() where T : class
	{
		using (mSubsystemMonitor.Enter())
		{
			return mSubsystems.ContainsKey(typeof(T));
		}
	}

	// ===== Component Factory =====

	/// Discovers all types with [EngineComponent] attribute and registers them
	/// in the component factory. Call this once after all assemblies are loaded.
	public void DiscoverComponents()
	{
		mLogger?.LogInformation("Discovering engine components...");
		int count = 0;

		for (let type in Type.Types)
		{
			if (type.IsAbstract)
				continue;

			if (let attr = type.GetCustomAttribute<EngineComponentAttribute>())
			{
				let info = new ComponentInfo();
				info.ComponentType = type;
				info.Category.Set(attr.Category);
				type.GetName(info.TypeName);

				mComponentInfoList.Add(info);
				mComponentInfoByName[info.TypeName] = info;

				mLogger?.LogTrace("  Registered component: {} [{}]", info.TypeName, info.Category);
				count++;
			}
		}

		mLogger?.LogInformation("Discovered {} engine components.", count);
	}

	/// Creates a component instance by type name.
	/// Returns null if the type is not registered or creation fails.
	public Object CreateComponent(StringView typeName)
	{
		if (mComponentInfoByName.TryGetValue(scope String(typeName), let info))
		{
			if (info.ComponentType.CreateObject() case .Ok(let obj))
				return obj;
			else
				mLogger?.LogError("Failed to create component of type '{}'.", typeName);
		}
		else
		{
			mLogger?.LogError("Component type '{}' not registered.", typeName);
		}
		return null;
	}

	/// Gets info about a registered component type.
	/// Returns null if not registered.
	public ComponentInfo GetComponentInfo(StringView typeName)
	{
		if (mComponentInfoByName.TryGetValue(scope String(typeName), let info))
			return info;
		return null;
	}

	/// Gets a read-only list of all registered component types.
	public Span<ComponentInfo> RegisteredComponents => mComponentInfoList;
}
