using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Sedulous.Engine.Core;

/// Type of file change detected.
public enum FileChangeType
{
	/// A file was created.
	Created,
	/// A file was modified.
	Modified,
	/// A file was deleted.
	Deleted,
	/// A file was renamed.
	Renamed
}

/// A single file change event.
public struct FileChange
{
	public FileChangeType Type;
	public String Path;
	public String OldPath; // Only for Renamed
}

/// Monitors directories for file changes and triggers callbacks.
///
/// Polls the file system at a configurable interval (default 1 second)
/// to detect created, modified, and deleted files. Changes are queued
/// and dispatched on the calling thread during Update().
///
/// Usage:
///   let watcher = new FileWatcher();
///   watcher.AddDirectory("Data/Textures", "*.png;*.jpg", true);
///   watcher.OnFileChanged.Add(new (change) => { ... });
///   // In game loop:
///   watcher.Update(deltaTime);
///
public class FileWatcher
{
	/// Directory being watched.
	struct WatchedDirectory : IDisposable
	{
		public String Path;
		public String Extensions; // Semicolon-separated, e.g. "*.png;*.jpg"
		public bool Recursive;
		public Dictionary<String, DateTime> FileTimestamps;

		public void Dispose() mut
		{
			delete Path;
			delete Extensions;
			DeleteDictionaryAndKeys!(FileTimestamps);
		}
	}

	private List<WatchedDirectory> mDirectories = new .() ~ {
		for (var dir in _)
			dir.Dispose();
		delete _;
	};

	private List<FileChange> mPendingChanges = new .() ~ {
		for (var change in _)
		{
			delete change.Path;
			if (change.OldPath != null) delete change.OldPath;
		}
		delete _;
	};

	private Monitor mChangeLock = new .() ~ delete _;
	private float mPollInterval = 1.0f;
	private float mTimeSinceLastPoll = 0;
	private bool mEnabled = true;

	/// Fired when a file change is detected. Called during Update() on the main thread.
	public Event<delegate void(FileChange)> OnFileChanged ~ _.Dispose();

	// ===== Properties =====

	/// How often to poll for changes (seconds).
	public float PollInterval
	{
		get => mPollInterval;
		set => mPollInterval = Math.Max(value, 0.1f);
	}

	/// Whether the watcher is active.
	public bool Enabled
	{
		get => mEnabled;
		set => mEnabled = value;
	}

	/// Number of directories being watched.
	public int DirectoryCount => mDirectories.Count;

	// ===== Directory Management =====

	/// Adds a directory to watch.
	/// extensions: semicolon-separated patterns, e.g. "*.png;*.jpg;*.bmp" (empty = all files)
	/// recursive: whether to watch subdirectories
	public void AddDirectory(StringView path, StringView extensions = "", bool recursive = true)
	{
		var watched = WatchedDirectory()
		{
			Path = new String(path),
			Extensions = new String(extensions),
			Recursive = recursive,
			FileTimestamps = new .()
		};

		// Initial scan to capture baseline
		ScanDirectory(ref watched);
		mDirectories.Add(watched);
	}

	/// Removes a watched directory.
	public void RemoveDirectory(StringView path)
	{
		for (int i = mDirectories.Count - 1; i >= 0; i--)
		{
			if (StringView(mDirectories[i].Path) == path)
			{
				var dir = mDirectories[i];
				dir.Dispose();
				mDirectories.RemoveAt(i);
				break;
			}
		}
	}

	/// Removes all watched directories.
	public void ClearDirectories()
	{
		for (var dir in mDirectories)
			dir.Dispose();
		mDirectories.Clear();
	}

	// ===== Update =====

	/// Polls for changes and dispatches events. Call once per frame.
	public void Update(float deltaTime)
	{
		if (!mEnabled)
			return;

		mTimeSinceLastPoll += deltaTime;
		if (mTimeSinceLastPoll < mPollInterval)
			return;

		mTimeSinceLastPoll = 0;

		// Poll all directories
		for (var dir in ref mDirectories)
		{
			PollDirectory(ref dir);
		}

		// Dispatch pending changes
		DispatchChanges();
	}

	/// Forces an immediate poll of all directories.
	public void PollNow()
	{
		for (var dir in ref mDirectories)
		{
			PollDirectory(ref dir);
		}
		DispatchChanges();
	}

	// ===== Private =====

	private void ScanDirectory(ref WatchedDirectory dir)
	{
		let searchPath = scope String(dir.Path);

		for (let entry in Directory.EnumerateFiles(searchPath))
		{
			let filePath = scope String();
			entry.GetFilePath(filePath);

			if (!MatchesExtensions(filePath, dir.Extensions))
				continue;

			let writeTime = entry.GetLastWriteTime();
			let key = new String(filePath);
			dir.FileTimestamps[key] = writeTime;
		}
	}

	private void PollDirectory(ref WatchedDirectory dir)
	{
		// Track which files we've seen this poll
		let seenFiles = scope HashSet<StringView>();

		for (let entry in Directory.EnumerateFiles(dir.Path))
		{
			let filePath = scope String();
			entry.GetFilePath(filePath);

			if (!MatchesExtensions(filePath, dir.Extensions))
				continue;

			seenFiles.Add(StringView(filePath));
			let writeTime = entry.GetLastWriteTime();

			if (dir.FileTimestamps.TryGetValue(filePath, var existingTime))
			{
				// File exists — check if modified
				if (writeTime != existingTime)
				{
					dir.FileTimestamps[scope String(filePath)] = writeTime;
					QueueChange(.Modified, filePath);
				}
			}
			else
			{
				// New file
				let key = new String(filePath);
				dir.FileTimestamps[key] = writeTime;
				QueueChange(.Created, filePath);
			}
		}

		// Check for deleted files
		let deletedKeys = scope List<String>();
		for (let kv in dir.FileTimestamps)
		{
			if (!seenFiles.Contains(kv.key))
			{
				QueueChange(.Deleted, kv.key);
				deletedKeys.Add(kv.key);
			}
		}

		for (let key in deletedKeys)
		{
			if (dir.FileTimestamps.GetAndRemove(key) case .Ok(let pair))
				delete pair.key;
		}
	}

	private void QueueChange(FileChangeType type, StringView path)
	{
		using (mChangeLock.Enter())
		{
			FileChange change = .()
			{
				Type = type,
				Path = new String(path),
				OldPath = null
			};
			mPendingChanges.Add(change);
		}
	}

	private void DispatchChanges()
	{
		// Swap pending list
		let changes = scope List<FileChange>();
		using (mChangeLock.Enter())
		{
			for (let change in mPendingChanges)
				changes.Add(change);
			mPendingChanges.Clear();
		}

		// Fire events
		for (let change in changes)
		{
			OnFileChanged(change);
			delete change.Path;
			if (change.OldPath != null) delete change.OldPath;
		}
	}

	private static bool MatchesExtensions(StringView filePath, StringView extensions)
	{
		if (extensions.IsEmpty)
			return true;

		for (let pattern in extensions.Split(';'))
		{
			let trimmed = scope String(pattern);
			trimmed.Trim();
			if (trimmed.IsEmpty)
				continue;

			// Simple extension matching: "*.png" checks suffix ".png"
			if (trimmed.StartsWith("*."))
			{
				let ext = trimmed.Substring(1); // ".png"
				if (filePath.EndsWith(ext, .OrdinalIgnoreCase))
					return true;
			}
			else if (filePath.EndsWith(trimmed, .OrdinalIgnoreCase))
			{
				return true;
			}
		}

		return false;
	}
}
