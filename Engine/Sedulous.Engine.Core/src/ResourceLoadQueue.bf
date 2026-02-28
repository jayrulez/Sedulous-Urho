using System;
using System.Collections;
using Sedulous.Resources;
using Sedulous.Jobs;

namespace Sedulous.Engine.Core;

/// Progress info for a batch resource load operation.
public struct LoadProgress
{
	/// Total number of resources queued.
	public int32 Total;
	/// Number of resources that have completed loading (success or failure).
	public int32 Completed;
	/// Number of resources that failed to load.
	public int32 Failed;
	/// Name/path of the most recently completed resource.
	public StringView LastCompleted;

	/// Progress as a fraction (0.0 to 1.0).
	public float Fraction => Total > 0 ? (float)Completed / (float)Total : 1.0f;

	/// Whether all resources have finished loading.
	public bool IsComplete => Total > 0 && Completed >= Total;
}

/// Tracks a single queued resource load request.
struct QueuedLoad
{
	public String Path;
	public bool Completed;
	public bool Failed;
}

/// Batches multiple async resource loads and tracks overall progress.
///
/// Enqueue resource paths, call StartLoading(), then poll Progress each
/// frame until IsComplete is true. Fires OnProgress and OnComplete
/// callbacks for UI integration (loading screens, progress bars).
///
/// Usage:
///   let queue = new ResourceLoadQueue(resourceSystem);
///   queue.Enqueue<Texture>("textures/diffuse.png");
///   queue.Enqueue<Mesh>("models/hero.glb");
///   queue.OnComplete = new () => { StartGame(); };
///   queue.StartLoading();
///   // ... poll queue.Progress in update loop ...
///
public class ResourceLoadQueue
{
	private ResourceSystem mResourceSystem;
	private List<QueuedLoad> mQueue = new .() ~ {
		for (let q in _)
			delete q.Path;
		delete _;
	};
	private int32 mCompleted = 0;
	private int32 mFailed = 0;
	private String mLastCompleted = new .() ~ delete _;
	private bool mStarted = false;

	/// Called when progress changes (after each resource completes).
	public delegate void(LoadProgress) OnProgress ~ { if (_ != null) delete _; };

	/// Called when all queued resources have finished loading.
	public delegate void() OnComplete ~ { if (_ != null) delete _; };

	public this(ResourceSystem resourceSystem)
	{
		mResourceSystem = resourceSystem;
	}

	/// Current loading progress.
	public LoadProgress Progress
	{
		get => .()
		{
			Total = (int32)mQueue.Count,
			Completed = mCompleted,
			Failed = mFailed,
			LastCompleted = mLastCompleted
		};
	}

	/// Whether all queued resources have completed.
	public bool IsComplete => mStarted && mCompleted >= (int32)mQueue.Count;

	/// Number of queued resources.
	public int32 Count => (int32)mQueue.Count;

	/// Adds a resource to the load queue. Must be called before StartLoading().
	public void Enqueue(StringView path)
	{
		mQueue.Add(.() { Path = new String(path), Completed = false, Failed = false });
	}

	/// Starts loading all queued resources asynchronously.
	/// Each resource is submitted as a separate job to the JobSystem.
	public void StartLoading<T>() where T : IResource
	{
		mStarted = true;
		mCompleted = 0;
		mFailed = 0;

		for (int32 i = 0; i < mQueue.Count; i++)
		{
			let index = i;
			let path = mQueue[i].Path;

			mResourceSystem.LoadResourceAsync<T>(path,
				onCompleted: new (result) =>
				{
					mQueue[index].Completed = true;
					if (result case .Err)
					{
						mQueue[index].Failed = true;
						mFailed++;
					}
					mCompleted++;
					mLastCompleted.Set(mQueue[index].Path);

					OnProgress?.Invoke(Progress);

					if (IsComplete)
						OnComplete?.Invoke();
				});
		}
	}

	/// Resets the queue for reuse. Clears all entries and state.
	public void Reset()
	{
		for (let q in mQueue)
			delete q.Path;
		mQueue.Clear();
		mCompleted = 0;
		mFailed = 0;
		mLastCompleted.Clear();
		mStarted = false;
	}
}
