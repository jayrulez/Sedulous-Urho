using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Renderer;

/// Internal state for a single particle.
public struct Particle
{
	public Vector3 Position;
	public Vector3 Velocity;
	public float Lifetime;
	public float TimeAlive;
	public float Size;
	public float StartSize;
	public float EndSize;
	public uint32 StartColor;
	public uint32 EndColor;
	public float Rotation;
	public float RotationSpeed;
}

/// Drawable that emits and simulates camera-facing particles.
///
/// Extends BillboardSet by driving billboard properties from a simple
/// particle simulation: emission, velocity integration, gravity,
/// and size/color interpolation over each particle's lifetime.
///
[EngineComponent("Rendering")]
public class ParticleEmitter : BillboardSet
{
	private List<Particle> mParticles = new .() ~ delete _;
	private bool mEmitting = true;
	private float mEmissionTimer = 0;
	private Random mRandom = new .() ~ delete _;
	private ParticleEffect mEffect;

	// Emission
	private float mEmissionRate = 10.0f;
	private int32 mMaxParticles = 100;

	// Particle properties
	private float mMinLifetime = 1.0f;
	private float mMaxLifetime = 2.0f;
	private float mMinSpeed = 1.0f;
	private float mMaxSpeed = 3.0f;
	private float mMinSize = 0.5f;
	private float mMaxSize = 1.0f;
	private float mEndSizeScale = 0.0f;
	private Vector3 mGravity = .(0, -9.81f, 0);
	private Vector3 mEmissionDirection = .(0, 1, 0);
	private float mDirectionSpread = 0.5f;
	private uint32 mStartColor = 0xFFFFFFFF;
	private uint32 mEndColor = 0x00FFFFFF;
	private float mMinRotationSpeed = 0;
	private float mMaxRotationSpeed = 0;

	// ===== Properties =====

	/// Particles emitted per second.
	[Editable("Emission Rate")]
	public float EmissionRate
	{
		get => mEmissionRate;
		set => mEmissionRate = Math.Max(value, 0);
	}

	/// Maximum live particles at once.
	[Editable("Max Particles")]
	public int32 MaxParticles
	{
		get => mMaxParticles;
		set => mMaxParticles = Math.Max(value, 0);
	}

	/// Whether the emitter is actively spawning particles.
	public bool Emitting
	{
		get => mEmitting;
		set => mEmitting = value;
	}

	[Editable("Min Lifetime")]
	public float MinLifetime
	{
		get => mMinLifetime;
		set => mMinLifetime = Math.Max(value, 0.01f);
	}

	[Editable("Max Lifetime")]
	public float MaxLifetime
	{
		get => mMaxLifetime;
		set => mMaxLifetime = Math.Max(value, 0.01f);
	}

	[Editable("Min Speed")]
	public float MinSpeed { get => mMinSpeed; set => mMinSpeed = value; }

	[Editable("Max Speed")]
	public float MaxSpeed { get => mMaxSpeed; set => mMaxSpeed = value; }

	[Editable("Min Size")]
	public float MinSize
	{
		get => mMinSize;
		set => mMinSize = Math.Max(value, 0);
	}

	[Editable("Max Size")]
	public float MaxSize
	{
		get => mMaxSize;
		set => mMaxSize = Math.Max(value, 0);
	}

	/// End size as a fraction of start size (0 = shrink to nothing).
	[Editable("End Size Scale")]
	public float EndSizeScale { get => mEndSizeScale; set => mEndSizeScale = value; }

	/// Gravity applied to particles each frame (local space).
	public Vector3 Gravity { get => mGravity; set => mGravity = value; }

	/// Base emission direction (local space).
	public Vector3 EmissionDirection { get => mEmissionDirection; set => mEmissionDirection = value; }

	/// Emission cone half-angle in radians.
	[Editable("Direction Spread")]
	public float DirectionSpread
	{
		get => mDirectionSpread;
		set => mDirectionSpread = Math.Clamp(value, 0, Math.PI_f);
	}

	/// Start color (packed RGBA).
	public uint32 StartColor { get => mStartColor; set => mStartColor = value; }

	/// End color (packed RGBA).
	public uint32 EndColor { get => mEndColor; set => mEndColor = value; }

	/// Minimum rotation speed in radians/sec.
	[Editable("Min Rotation Speed")]
	public float MinRotationSpeed { get => mMinRotationSpeed; set => mMinRotationSpeed = value; }

	/// Maximum rotation speed in radians/sec.
	[Editable("Max Rotation Speed")]
	public float MaxRotationSpeed { get => mMaxRotationSpeed; set => mMaxRotationSpeed = value; }

	/// Number of currently live particles.
	public int32 ActiveParticleCount => (int32)mParticles.Count;

	/// Particle effect resource. Setting this applies all effect parameters to this emitter.
	public ParticleEffect Effect
	{
		get => mEffect;
		set
		{
			mEffect = value;
			if (mEffect != null)
				mEffect.ApplyTo(this);
		}
	}

	// ===== Control =====

	/// Starts emitting particles.
	public void Start() { mEmitting = true; }

	/// Stops emitting (existing particles continue to live).
	public void Stop() { mEmitting = false; }

	/// Stops emitting and removes all live particles.
	public void Reset()
	{
		mParticles.Clear();
		mEmissionTimer = 0;
		SetBillboardCount(0);
	}

	// ===== Update =====

	public override void UpdateBatches(FrameInfo frameInfo)
	{
		let dt = frameInfo.TimeStep;

		// Emit new particles
		if (mEmitting && mEmissionRate > 0)
		{
			mEmissionTimer += dt;
			let interval = 1.0f / mEmissionRate;
			while (mEmissionTimer >= interval && mParticles.Count < mMaxParticles)
			{
				EmitParticle();
				mEmissionTimer -= interval;
			}
			// Clamp to avoid burst after long pause
			if (mEmissionTimer > interval * 2)
				mEmissionTimer = 0;
		}

		// Update existing particles
		for (int i = mParticles.Count - 1; i >= 0; i--)
		{
			mParticles[i].TimeAlive += dt;

			if (mParticles[i].TimeAlive >= mParticles[i].Lifetime)
			{
				mParticles.RemoveAtFast(i);
				continue;
			}

			mParticles[i].Velocity += mGravity * dt;
			mParticles[i].Position += mParticles[i].Velocity * dt;
			mParticles[i].Rotation += mParticles[i].RotationSpeed * dt;

			let t = mParticles[i].TimeAlive / mParticles[i].Lifetime;
			mParticles[i].Size = Lerp(mParticles[i].StartSize, mParticles[i].EndSize, t);
		}

		// Sync billboards from particles
		SetBillboardCount((int32)mParticles.Count);
		for (int32 i = 0; i < (.)mParticles.Count; i++)
		{
			let p = mParticles[i];
			let t = p.TimeAlive / p.Lifetime;

			var bb = Billboard();
			bb.Position = p.Position;
			bb.Size = .(p.Size, p.Size);
			bb.Color = LerpColor(p.StartColor, p.EndColor, t);
			bb.Rotation = p.Rotation;
			bb.UV = .(0, 0, 1, 1);
			bb.Enabled = true;
			SetBillboard(i, bb);
		}

		// Base generates camera-facing geometry and submits batches
		base.UpdateBatches(frameInfo);
	}

	// ===== Private =====

	private void EmitParticle()
	{
		var p = Particle();
		p.Position = .Zero;
		p.Lifetime = RandRange(mMinLifetime, mMaxLifetime);
		p.TimeAlive = 0;
		p.StartSize = RandRange(mMinSize, mMaxSize);
		p.EndSize = p.StartSize * mEndSizeScale;
		p.Size = p.StartSize;
		p.StartColor = mStartColor;
		p.EndColor = mEndColor;
		p.Rotation = 0;
		p.RotationSpeed = RandRange(mMinRotationSpeed, mMaxRotationSpeed);

		let speed = RandRange(mMinSpeed, mMaxSpeed);
		let dir = RandomDirectionInCone(mEmissionDirection, mDirectionSpread);
		p.Velocity = dir * speed;

		mParticles.Add(p);
	}

	private Vector3 RandomDirectionInCone(Vector3 baseDir, float halfAngle)
	{
		if (halfAngle <= 0.001f)
			return Vector3.Normalize(baseDir);

		let theta = RandRange(0, halfAngle);
		let phi = RandRange(0, Math.PI_f * 2.0f);

		// Random direction in cone around +Y
		let sinTheta = Math.Sin(theta);
		Vector3 localDir = .(sinTheta * Math.Cos(phi), Math.Cos(theta), sinTheta * Math.Sin(phi));

		// Rotate from +Y to baseDir
		let normalizedBase = Vector3.Normalize(baseDir);
		let dotY = Vector3.Dot(normalizedBase, .(0, 1, 0));
		if (Math.Abs(dotY) > 0.999f)
			return localDir * (dotY > 0 ? 1.0f : -1.0f);

		let right = Vector3.Normalize(Vector3.Cross(.(0, 1, 0), normalizedBase));
		let up = Vector3.Cross(normalizedBase, right);
		return right * localDir.X + normalizedBase * localDir.Y + up * localDir.Z;
	}

	private float RandRange(float min, float max)
	{
		return min + (float)mRandom.NextDouble() * (max - min);
	}

	private static float Lerp(float a, float b, float t)
	{
		return a + (b - a) * t;
	}

	private static uint32 LerpColor(uint32 a, uint32 b, float t)
	{
		let ar = (float)(a & 0xFF);
		let ag = (float)((a >> 8) & 0xFF);
		let ab = (float)((a >> 16) & 0xFF);
		let aa = (float)((a >> 24) & 0xFF);

		let br = (float)(b & 0xFF);
		let bg = (float)((b >> 8) & 0xFF);
		let bb2 = (float)((b >> 16) & 0xFF);
		let ba = (float)((b >> 24) & 0xFF);

		return ((uint32)Lerp(ar, br, t)) |
			   ((uint32)Lerp(ag, bg, t) << 8) |
			   ((uint32)Lerp(ab, bb2, t) << 16) |
			   ((uint32)Lerp(aa, ba, t) << 24);
	}
}
