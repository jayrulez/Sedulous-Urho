using System;
using System.Collections;

namespace Sedulous.Engine.Core;

/// Resource category for memory budget tracking.
public enum ResourceCategory : uint8
{
	/// GPU textures (albedo, normal, specular, etc.).
	Textures,
	/// GPU vertex/index buffers for meshes.
	Meshes,
	/// Shader programs and pipeline state objects.
	Shaders,
	/// Audio samples and streams.
	Audio,
	/// Animation clips and skeletal data.
	Animations,
	/// Other uncategorized resources.
	Other
}

/// Tracks memory usage for a single resource category.
public struct CategoryBudget
{
	/// Maximum allowed memory in bytes (0 = unlimited).
	public uint64 Limit;
	/// Current allocated memory in bytes.
	public uint64 Current;
	/// Peak allocated memory this session.
	public uint64 Peak;
	/// Number of active allocations.
	public int32 Count;

	/// Fraction of budget used (0.0 to 1.0+). Returns 0 if unlimited.
	public float Usage => Limit > 0 ? (float)Current / (float)Limit : 0;

	/// Whether the budget is exceeded.
	public bool IsOverBudget => Limit > 0 && Current > Limit;
}

/// Tracks a single allocation for LRU eviction.
struct AllocationEntry
{
	public String Name;
	public ResourceCategory Category;
	public uint64 Size;
	public uint64 LastUsedFrame;
}

/// Tracks GPU and CPU memory usage per resource type with configurable budgets.
///
/// Register allocations when creating GPU resources, and release them when
/// destroyed. The budget system tracks per-category usage and provides
/// LRU-based eviction hints when a category exceeds its limit.
///
/// Usage:
///   let budget = new MemoryBudget();
///   budget.SetLimit(.Textures, 512 * 1024 * 1024); // 512MB
///   budget.Allocate(.Textures, "diffuse.png", textureSize);
///   ...
///   budget.Release(.Textures, "diffuse.png");
///
public class MemoryBudget
{
	private CategoryBudget[(int)ResourceCategory.Other + 1] mBudgets = default;
	private Dictionary<String, AllocationEntry> mAllocations = new .() ~ {
		for (let kv in _)
		{
			delete kv.key;
			delete kv.value.Name;
		}
		delete _;
	};
	private uint64 mCurrentFrame = 0;

	/// Sets the memory limit for a category (in bytes). 0 = unlimited.
	public void SetLimit(ResourceCategory category, uint64 limitBytes)
	{
		mBudgets[(int)category].Limit = limitBytes;
	}

	/// Gets the budget info for a category.
	public CategoryBudget GetBudget(ResourceCategory category)
	{
		return mBudgets[(int)category];
	}

	/// Total allocated memory across all categories.
	public uint64 TotalAllocated
	{
		get
		{
			uint64 total = 0;
			for (int i = 0; i <= (int)ResourceCategory.Other; i++)
				total += mBudgets[i].Current;
			return total;
		}
	}

	/// Registers a memory allocation.
	public void Allocate(ResourceCategory category, StringView name, uint64 sizeBytes)
	{
		let key = new String(name);
		let entry = AllocationEntry()
		{
			Name = new String(name),
			Category = category,
			Size = sizeBytes,
			LastUsedFrame = mCurrentFrame
		};

		// If already tracked, release old first
		if (mAllocations.ContainsKey(key))
		{
			Release(category, name);
			delete key;
		}

		mAllocations[new String(name)] = entry;
		mBudgets[(int)category].Current += sizeBytes;
		mBudgets[(int)category].Count++;

		if (mBudgets[(int)category].Current > mBudgets[(int)category].Peak)
			mBudgets[(int)category].Peak = mBudgets[(int)category].Current;

		delete key;
	}

	/// Releases a previously tracked allocation.
	public void Release(ResourceCategory category, StringView name)
	{
		let searchKey = scope String(name);
		if (mAllocations.GetAndRemove(searchKey) case .Ok(let pair))
		{
			mBudgets[(int)category].Current -= Math.Min(pair.value.Size, mBudgets[(int)category].Current);
			mBudgets[(int)category].Count--;
			delete pair.key;
			delete pair.value.Name;
		}
	}

	/// Marks an allocation as recently used (updates LRU timestamp).
	public void Touch(StringView name)
	{
		let searchKey = scope String(name);
		if (mAllocations.TryGetRefAlt(searchKey, var keyPtr, var valuePtr))
		{
			valuePtr.LastUsedFrame = mCurrentFrame;
		}
	}

	/// Called once per frame to advance the frame counter.
	public void Update(uint64 frameNumber)
	{
		mCurrentFrame = frameNumber;
	}

	/// Gets the names of allocations that should be evicted to bring
	/// the given category under budget, ordered by least recently used.
	/// Returns the total bytes that would be freed.
	public uint64 GetEvictionCandidates(ResourceCategory category, List<String> outNames)
	{
		let budget = mBudgets[(int)category];
		if (!budget.IsOverBudget)
			return 0;

		uint64 overBy = budget.Current - budget.Limit;

		// Collect all allocations in this category, sorted by last used frame (oldest first)
		let candidates = scope List<(String name, uint64 size, uint64 frame)>();
		for (let kv in mAllocations)
		{
			if (kv.value.Category == category)
				candidates.Add((kv.key, kv.value.Size, kv.value.LastUsedFrame));
		}

		candidates.Sort(scope (a, b) => {
			if (a.frame < b.frame) return -1;
			if (a.frame > b.frame) return 1;
			return 0;
		});

		uint64 freed = 0;
		for (let candidate in candidates)
		{
			if (freed >= overBy)
				break;
			outNames.Add(candidate.name);
			freed += candidate.size;
		}

		return freed;
	}

	/// Whether any category is over its budget.
	public bool IsAnyOverBudget
	{
		get
		{
			for (int i = 0; i <= (int)ResourceCategory.Other; i++)
				if (mBudgets[i].IsOverBudget)
					return true;
			return false;
		}
	}

	/// Formats budget stats for debug display.
	public void FormatStats(String output)
	{
		String[?] names = .("Textures", "Meshes", "Shaders", "Audio", "Animations", "Other");
		for (int i = 0; i <= (int)ResourceCategory.Other; i++)
		{
			let b = mBudgets[i];
			if (b.Count == 0 && b.Limit == 0)
				continue;
			output.AppendF("{}: {:.1}MB / {:.1}MB ({} items)\n",
				names[i],
				(float)b.Current / (1024.0f * 1024.0f),
				b.Limit > 0 ? (float)b.Limit / (1024.0f * 1024.0f) : 0.0f,
				b.Count);
		}
	}
}
