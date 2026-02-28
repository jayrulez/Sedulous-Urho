using System;
using System.Threading;
using System.Diagnostics;
using System.Reflection;
using Sedulous.Serialization;
using Sedulous.Foundation.Core;

namespace Sedulous.Resources;

/// Abstract base class for all resources.
/// Provides reference counting, serialization support, state tracking, and events.
abstract class Resource : IResource, ISerializable
{
	private int32 mRefCount = 0;
	private Guid mId;
	private String mName = new .() ~ delete _;
	private String mResourceType = new .() ~ delete _;
	private ResourceState mState = .Empty;
	private String mPath = new .() ~ delete _;
	private uint64 mFileSize = 0;
	private EventAccessor<delegate void(ResourceState, ResourceState, Resource)> mStateChanged = new .() ~ delete _;

	// ---- Identity ----

	/// Gets or sets the unique identifier.
	public Guid Id
	{
		get => mId;
		set => mId = value;
	}

	/// Gets or sets the resource name.
	public String Name
	{
		get => mName;
		set { mName.Set(value); }
	}

	/// Gets the resource file type identifier (fully qualified class name).
	public StringView ResourceType => mResourceType;

	/// Gets the current reference count.
	public int RefCount => mRefCount;

	// ---- State Tracking ----

	/// The current loading state.
	public ResourceState State => mState;

	/// Whether the resource is in the Empty (not loaded) state.
	public bool IsEmpty => mState == .Empty;

	/// Whether the resource has been loaded and is ready for use.
	public bool IsReady => mState == .Ready;

	/// Whether loading has failed.
	public bool IsFailure => mState == .Failure;

	/// The file path of this resource.
	public StringView Path => mPath;

	/// The size of the loaded resource data in bytes.
	public uint64 FileSize => mFileSize;

	/// Subscribe to state change notifications.
	public EventAccessor<delegate void(ResourceState, ResourceState, Resource)> OnStateChanged => mStateChanged;

	// ---- Construction ----

	public this()
	{
		mId = Guid.Create();
		GetType().GetFullName(mResourceType);
	}

	public ~this()
	{
		Debug.Assert(mRefCount == 0, "Resource deleted with non-zero ref count");
	}

	// ---- Reference Counting ----

	/// Increments the reference count.
	public void AddRef()
	{
		Interlocked.Increment(ref mRefCount);
	}

	/// Decrements the reference count. Deletes when count reaches zero.
	public void ReleaseRef()
	{
		let refCount = Interlocked.Decrement(ref mRefCount);
		Debug.Assert(refCount >= 0);
		if (refCount == 0)
			delete this;
	}
	
	public void ReleaseLastRef()
	{
		int refCount = Interlocked.Decrement(ref mRefCount);
		Debug.Assert(refCount == 0);
		if (refCount == 0)
		{
			delete this;
		}
	}

	/// Decrements the reference count without deleting.
	public int ReleaseRefNoDelete()
	{
		let refCount = Interlocked.Decrement(ref mRefCount);
		Debug.Assert(refCount >= 0);
		return refCount;
	}

	// ---- State Management ----

	/// Set the loading state. Fires OnStateChanged event if state changes.
	public void SetState(ResourceState newState)
	{
		let oldState = mState;
		mState = newState;
		if (oldState != newState)
			mStateChanged.[Friend]Invoke(oldState, newState, this);
	}

	/// Set the file path of this resource.
	public void SetPath(StringView path)
	{
		mPath.Set(path);
	}

	/// Set the file size of this resource.
	public void SetFileSize(uint64 size)
	{
		mFileSize = size;
	}

	// ---- ISerializable ----

	/// Gets the serialization version for this resource type.
	public virtual int32 SerializationVersion => 1;

	/// Serializes the resource.
	public virtual SerializationResult Serialize(Serializer s)
	{
		// Serialize resource type
		if (s.IsWriting)
		{
			s.String("_type", mResourceType);
		}
		else
		{
			let fileType = scope String();
			s.String("_type", fileType);
			if (fileType != mResourceType)
				return .InvalidData;
		}

		var version = SerializationVersion;
		s.Version(ref version);

		// Serialize GUID as string
		let guidStr = scope String();
		if (s.IsWriting)
			mId.ToString(guidStr);
		s.String("_id", guidStr);
		if (s.IsReading)
			mId = Guid.Parse(guidStr).GetValueOrDefault();

		s.String("_name", mName);

		return OnSerialize(s);
	}

	/// Override to serialize resource-specific data.
	protected virtual SerializationResult OnSerialize(Serializer s)
	{
		return .Ok;
	}
}
