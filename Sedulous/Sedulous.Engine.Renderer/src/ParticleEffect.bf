using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Resources;
using Sedulous.Serialization;

using static Sedulous.Resources.ResourceSerializerExtensions;

namespace Sedulous.Engine.Renderer;

/// Data-driven particle system definition resource.
///
/// Defines all parameters for a particle emitter: emission rate, lifetime,
/// speed, size, color, gravity, direction, and rotation. Load from file
/// and apply to a ParticleEmitter via ApplyEffect().
///
public class ParticleEffect : Resource
{
	// Emission
	public float EmissionRate = 10.0f;
	public int32 MaxParticles = 100;

	// Lifetime
	public float MinLifetime = 1.0f;
	public float MaxLifetime = 2.0f;

	// Speed
	public float MinSpeed = 1.0f;
	public float MaxSpeed = 3.0f;

	// Size
	public float MinSize = 0.5f;
	public float MaxSize = 1.0f;
	public float EndSizeScale = 0.0f;

	// Direction
	public float DirectionX = 0;
	public float DirectionY = 1;
	public float DirectionZ = 0;
	public float DirectionSpread = 0.5f;

	// Gravity
	public float GravityX = 0;
	public float GravityY = -9.81f;
	public float GravityZ = 0;

	// Color (packed RGBA)
	public uint32 StartColor = 0xFFFFFFFF;
	public uint32 EndColor = 0x00FFFFFF;

	// Rotation
	public float MinRotationSpeed = 0;
	public float MaxRotationSpeed = 0;

	// Material reference
	public ResourceRef MaterialRef = .();

	public ~this()
	{
		MaterialRef.Dispose();
	}

	// ===== Convenience =====

	/// Emission direction as a Vector3.
	public Vector3 EmissionDirection
	{
		get => .(DirectionX, DirectionY, DirectionZ);
		set { DirectionX = value.X; DirectionY = value.Y; DirectionZ = value.Z; }
	}

	/// Gravity as a Vector3.
	public Vector3 Gravity
	{
		get => .(GravityX, GravityY, GravityZ);
		set { GravityX = value.X; GravityY = value.Y; GravityZ = value.Z; }
	}

	/// Applies this effect's parameters to a ParticleEmitter.
	public void ApplyTo(ParticleEmitter emitter)
	{
		emitter.EmissionRate = EmissionRate;
		emitter.MaxParticles = MaxParticles;
		emitter.MinLifetime = MinLifetime;
		emitter.MaxLifetime = MaxLifetime;
		emitter.MinSpeed = MinSpeed;
		emitter.MaxSpeed = MaxSpeed;
		emitter.MinSize = MinSize;
		emitter.MaxSize = MaxSize;
		emitter.EndSizeScale = EndSizeScale;
		emitter.EmissionDirection = EmissionDirection;
		emitter.DirectionSpread = DirectionSpread;
		emitter.Gravity = Gravity;
		emitter.StartColor = StartColor;
		emitter.EndColor = EndColor;
		emitter.MinRotationSpeed = MinRotationSpeed;
		emitter.MaxRotationSpeed = MaxRotationSpeed;
	}

	/// Captures the current parameters from a ParticleEmitter into this effect.
	public void CaptureFrom(ParticleEmitter emitter)
	{
		EmissionRate = emitter.EmissionRate;
		MaxParticles = emitter.MaxParticles;
		MinLifetime = emitter.MinLifetime;
		MaxLifetime = emitter.MaxLifetime;
		MinSpeed = emitter.MinSpeed;
		MaxSpeed = emitter.MaxSpeed;
		MinSize = emitter.MinSize;
		MaxSize = emitter.MaxSize;
		EndSizeScale = emitter.EndSizeScale;
		EmissionDirection = emitter.EmissionDirection;
		DirectionSpread = emitter.DirectionSpread;
		Gravity = emitter.Gravity;
		StartColor = emitter.StartColor;
		EndColor = emitter.EndColor;
		MinRotationSpeed = emitter.MinRotationSpeed;
		MaxRotationSpeed = emitter.MaxRotationSpeed;
	}

	// ===== Serialization =====

	public override int32 SerializationVersion => 1;

	protected override SerializationResult OnSerialize(Serializer s)
	{
		// Emission
		s.Float("emissionRate", ref EmissionRate);
		s.Int32("maxParticles", ref MaxParticles);

		// Lifetime
		s.Float("minLifetime", ref MinLifetime);
		s.Float("maxLifetime", ref MaxLifetime);

		// Speed
		s.Float("minSpeed", ref MinSpeed);
		s.Float("maxSpeed", ref MaxSpeed);

		// Size
		s.Float("minSize", ref MinSize);
		s.Float("maxSize", ref MaxSize);
		s.Float("endSizeScale", ref EndSizeScale);

		// Direction
		s.Float("directionX", ref DirectionX);
		s.Float("directionY", ref DirectionY);
		s.Float("directionZ", ref DirectionZ);
		s.Float("directionSpread", ref DirectionSpread);

		// Gravity
		s.Float("gravityX", ref GravityX);
		s.Float("gravityY", ref GravityY);
		s.Float("gravityZ", ref GravityZ);

		// Color
		s.UInt32("startColor", ref StartColor);
		s.UInt32("endColor", ref EndColor);

		// Rotation
		s.Float("minRotationSpeed", ref MinRotationSpeed);
		s.Float("maxRotationSpeed", ref MaxRotationSpeed);

		// Material
		s.ResourceRef("material", ref MaterialRef);

		return .Ok;
	}
}
