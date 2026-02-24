using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Audio;

/// Scene component for 2D (non-spatialized) audio playback.
///
/// Wraps an IAudioSource. Attach to any node. Controls volume, pitch,
/// looping, and play/stop. For 3D spatialized audio, use SoundSource3D.
///
public class SoundSource : Component
{
	private IAudioSystem mAudioSystem;
	private IAudioSource mSource;
	private AudioClip mCurrentClip;

	// Cached properties
	private float mVolume = 1.0f;
	private float mPitch = 1.0f;
	private bool mLoop = false;
	private bool mAutoPlay = false;

	public ~this()
	{
		ReleaseSource();
	}

	// ===== Properties =====

	/// Current playback state.
	public AudioSourceState State => mSource != null ? mSource.State : .Stopped;

	/// Whether audio is currently playing.
	public bool IsPlaying => State == .Playing;

	/// Volume (0.0 to 1.0).
	[Editable("Volume")]
	public float Volume
	{
		get => mVolume;
		set
		{
			mVolume = Math.Clamp(value, 0.0f, 1.0f);
			if (mSource != null)
				mSource.Volume = mVolume;
		}
	}

	/// Pitch multiplier (1.0 = normal).
	[Editable("Pitch")]
	public float Pitch
	{
		get => mPitch;
		set
		{
			mPitch = Math.Max(value, 0.01f);
			if (mSource != null)
				mSource.Pitch = mPitch;
		}
	}

	/// Whether playback loops.
	[Editable("Loop")]
	public bool Loop
	{
		get => mLoop;
		set
		{
			mLoop = value;
			if (mSource != null)
				mSource.Loop = value;
		}
	}

	/// Whether to start playing when the source is initialized.
	[Editable("Auto Play")]
	public bool AutoPlay
	{
		get => mAutoPlay;
		set => mAutoPlay = value;
	}

	/// The underlying audio source.
	public IAudioSource Source => mSource;

	// ===== Initialization =====

	/// Initializes this component with an audio system.
	/// Creates the underlying IAudioSource.
	public void Initialize(IAudioSystem audioSystem)
	{
		ReleaseSource();
		mAudioSystem = audioSystem;

		if (audioSystem != null)
		{
			mSource = audioSystem.CreateSource();
			if (mSource != null)
			{
				mSource.Volume = mVolume;
				mSource.Pitch = mPitch;
				mSource.Loop = mLoop;
			}
		}
	}

	// ===== Playback =====

	/// Plays an audio clip.
	public void Play(AudioClip clip)
	{
		if (mSource == null)
			return;

		mCurrentClip = clip;
		mSource.Play(clip);
	}

	/// Plays the previously set clip.
	public void Play()
	{
		if (mSource != null && mCurrentClip != null)
			mSource.Play(mCurrentClip);
	}

	/// Pauses playback.
	public void Pause()
	{
		if (mSource != null)
			mSource.Pause();
	}

	/// Resumes paused playback.
	public void Resume()
	{
		if (mSource != null)
			mSource.Resume();
	}

	/// Stops playback.
	public void Stop()
	{
		if (mSource != null)
			mSource.Stop();
	}

	/// Sets the audio clip without playing it.
	public void SetClip(AudioClip clip)
	{
		mCurrentClip = clip;
		if (mAutoPlay && mSource != null && clip != null)
			mSource.Play(clip);
	}

	// ===== Private =====

	private void ReleaseSource()
	{
		if (mSource != null && mAudioSystem != null)
		{
			mSource.Stop();
			mAudioSystem.DestroySource(mSource);
			mSource = null;
		}
	}

	protected override void OnRemoved()
	{
		ReleaseSource();
		mAudioSystem = null;
	}

	protected override void OnDisabled()
	{
		if (mSource != null && mSource.State == .Playing)
			mSource.Pause();
	}

	protected override void OnEnabled()
	{
		if (mSource != null && mSource.State == .Paused)
			mSource.Resume();
	}
}
