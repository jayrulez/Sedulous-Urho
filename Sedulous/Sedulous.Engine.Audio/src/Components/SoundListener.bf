using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Audio;

/// Scene component that marks a node as the active audio listener.
///
/// Syncs the audio system's listener position and orientation to the
/// owning node's world transform. Typically attached to the camera node.
/// Only one SoundListener should be active at a time.
///
public class SoundListener : Component
{
	private IAudioSystem mAudioSystem;

	// ===== Initialization =====

	/// Sets the audio system whose listener this component controls.
	public void Initialize(IAudioSystem audioSystem)
	{
		mAudioSystem = audioSystem;
		UpdateListener();
	}

	/// The audio system this listener is bound to.
	public IAudioSystem AudioSystem => mAudioSystem;

	// ===== Listener Sync =====

	/// Updates the audio listener from the node's world transform.
	public void UpdateListener()
	{
		if (mAudioSystem == null || Node == null)
			return;

		let listener = mAudioSystem.Listener;
		if (listener == null)
			return;

		listener.Position = Node.WorldPosition;
		listener.Forward = Node.WorldDirection;
		listener.Up = Node.WorldUp;
	}

	protected override void OnTransformChanged()
	{
		UpdateListener();
	}

	protected override void OnRemoved()
	{
		mAudioSystem = null;
	}
}
