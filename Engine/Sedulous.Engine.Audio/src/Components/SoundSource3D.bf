using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Audio;

/// Scene component for 3D spatialized audio playback.
///
/// Extends SoundSource with 3D positioning. The audio source position
/// is automatically synced to the owning node's world position.
/// Configure MinDistance and MaxDistance for attenuation control.
///
public class SoundSource3D : SoundSource
{
	private float mMinDistance = 1.0f;
	private float mMaxDistance = 100.0f;

	// ===== Properties =====

	/// Minimum distance — below this, audio is at full volume.
	[Editable("Min Distance")]
	public float MinDistance
	{
		get => mMinDistance;
		set
		{
			mMinDistance = Math.Max(value, 0.0f);
			if (Source != null)
				Source.MinDistance = mMinDistance;
		}
	}

	/// Maximum distance — beyond this, audio is inaudible.
	[Editable("Max Distance")]
	public float MaxDistance
	{
		get => mMaxDistance;
		set
		{
			mMaxDistance = Math.Max(value, mMinDistance);
			if (Source != null)
				Source.MaxDistance = mMaxDistance;
		}
	}

	// ===== Initialization =====

	/// Initializes this 3D sound source.
	public new void Initialize(IAudioSystem audioSystem)
	{
		base.Initialize(audioSystem);

		if (Source != null)
		{
			Source.MinDistance = mMinDistance;
			Source.MaxDistance = mMaxDistance;
			UpdateSourcePosition();
		}
	}

	// ===== Transform Sync =====

	/// Updates the audio source position from the node's world transform.
	public void UpdateSourcePosition()
	{
		if (Source != null && Node != null)
			Source.Position = Node.WorldPosition;
	}

	protected override void OnTransformChanged()
	{
		UpdateSourcePosition();
	}
}
