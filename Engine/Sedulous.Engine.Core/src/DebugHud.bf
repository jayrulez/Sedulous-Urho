using System;
using System.Collections;

namespace Sedulous.Engine.Core;

/// Debug overlay that collects and formats engine statistics.
///
/// Tracks frame timing, FPS, and custom stat values. Subscribe to
/// Engine.OnFrameEnd to call Update() each frame. Read FormattedText
/// to display the stats in your UI.
///
public class DebugHud
{
	private Engine mEngine;
	private bool mVisible = false;

	// FPS tracking
	private float mFpsAccumulator = 0;
	private int32 mFpsFrameCount = 0;
	private float mCurrentFps = 0;
	private float mFpsUpdateInterval = 0.5f;

	// Frame time tracking
	private float mFrameTimeMs = 0;
	private float mMinFrameTimeMs = float.MaxValue;
	private float mMaxFrameTimeMs = 0;

	// Custom stats
	private Dictionary<String, String> mStats = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	// Formatted output
	private String mFormattedText = new .() ~ delete _;

	public this(Engine engine)
	{
		mEngine = engine;
	}

	// ===== Properties =====

	/// Whether the debug HUD is visible.
	public bool Visible
	{
		get => mVisible;
		set => mVisible = value;
	}

	/// Toggle visibility on/off.
	public void Toggle()
	{
		mVisible = !mVisible;
	}

	/// Current frames per second.
	public float FPS => mCurrentFps;

	/// Current frame time in milliseconds.
	public float FrameTimeMs => mFrameTimeMs;

	/// Minimum frame time since last reset.
	public float MinFrameTimeMs => mMinFrameTimeMs;

	/// Maximum frame time since last reset.
	public float MaxFrameTimeMs => mMaxFrameTimeMs;

	/// How often FPS is recalculated (in seconds).
	public float FpsUpdateInterval
	{
		get => mFpsUpdateInterval;
		set => mFpsUpdateInterval = Math.Max(value, 0.1f);
	}

	/// The formatted stats text for display.
	public StringView FormattedText => mFormattedText;

	/// Current frame number from the engine.
	public uint64 FrameNumber => mEngine.FrameNumber;

	// ===== Custom Stats =====

	/// Sets a custom stat value for display.
	public void SetStat(StringView name, StringView value)
	{
		if (mStats.TryGetValue(scope String(name), var existingValue))
		{
			existingValue.Set(value);
		}
		else
		{
			mStats[new String(name)] = new String(value);
		}
	}

	/// Sets a custom integer stat.
	public void SetStat(StringView name, int32 value)
	{
		let str = scope String();
		value.ToString(str);
		SetStat(name, str);
	}

	/// Sets a custom float stat.
	public void SetStat(StringView name, float value)
	{
		let str = scope String();
		str.AppendF("{0:F2}", value);
		SetStat(name, str);
	}

	/// Removes a custom stat.
	public void RemoveStat(StringView name)
	{
		let key = scope String(name);
		if (mStats.TryGetValue(key, var kv))
		{
			let k = mStats.GetAndRemove(key);
			if (k case .Ok(let pair))
			{
				delete pair.key;
				delete pair.value;
			}
		}
	}

	/// Clears all custom stats.
	public void ClearStats()
	{
		DeleteDictionaryAndKeysAndValues!(mStats);
		mStats = new .();
	}

	// ===== Update =====

	/// Updates the debug HUD stats. Call once per frame.
	public void Update(float deltaTime)
	{
		// Frame time
		mFrameTimeMs = deltaTime * 1000.0f;
		if (mFrameTimeMs < mMinFrameTimeMs)
			mMinFrameTimeMs = mFrameTimeMs;
		if (mFrameTimeMs > mMaxFrameTimeMs)
			mMaxFrameTimeMs = mFrameTimeMs;

		// FPS calculation
		mFpsAccumulator += deltaTime;
		mFpsFrameCount++;
		if (mFpsAccumulator >= mFpsUpdateInterval)
		{
			mCurrentFps = (float)mFpsFrameCount / mFpsAccumulator;
			mFpsAccumulator = 0;
			mFpsFrameCount = 0;
		}

		// Format text
		if (mVisible)
			FormatText();
	}

	/// Resets min/max frame time tracking.
	public void ResetMinMax()
	{
		mMinFrameTimeMs = float.MaxValue;
		mMaxFrameTimeMs = 0;
	}

	// ===== Private =====

	private void FormatText()
	{
		mFormattedText.Clear();
		mFormattedText.AppendF("FPS: {0:F1}\n", mCurrentFps);
		mFormattedText.AppendF("Frame: {0:F2} ms\n", mFrameTimeMs);
		mFormattedText.AppendF("Min: {0:F2} ms  Max: {1:F2} ms\n", mMinFrameTimeMs, mMaxFrameTimeMs);
		mFormattedText.AppendF("Frame #: {}\n", mEngine.FrameNumber);

		if (mStats.Count > 0)
		{
			mFormattedText.Append("---\n");
			for (let kv in mStats)
			{
				mFormattedText.AppendF("{}: {}\n", kv.key, kv.value);
			}
		}
	}
}
