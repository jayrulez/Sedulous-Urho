using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Physics;

/// Scene component that wraps a physics body.
///
/// Requires a CollisionShape on the same node. Syncs the node's world
/// transform with the physics body each frame. For dynamic bodies, the
/// physics simulation drives the node transform. For kinematic bodies,
/// the node transform drives the physics body.
///
public class RigidBody : Component
{
	private BodyHandle mBodyHandle = .Invalid;
	private PhysicsWorld mPhysicsWorld;

	// Cached properties (applied when body is created)
	private BodyType mBodyType = .Dynamic;
	private float mMass = 1.0f;
	private float mFriction = 0.5f;
	private float mRestitution = 0.0f;
	private float mLinearDamping = 0.05f;
	private float mAngularDamping = 0.05f;
	private float mGravityFactor = 1.0f;
	private bool mAllowSleep = true;
	private bool mIsSensor = false;

	public ~this()
	{
		DestroyBody();
	}

	// ===== Properties =====

	/// The physics body handle.
	public BodyHandle BodyHandle => mBodyHandle;

	/// Whether this body has been created in the physics world.
	public bool IsCreated => mBodyHandle.IsValid;

	/// Whether the physics body is currently active (not sleeping).
	public bool IsActive => mPhysicsWorld?.World != null && mBodyHandle.IsValid && mPhysicsWorld.World.IsBodyActive(mBodyHandle);

	/// Body motion type.
	[Editable("Body Type")]
	public BodyType BodyType
	{
		get => mBodyType;
		set
		{
			mBodyType = value;
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyType(mBodyHandle, value);
		}
	}

	/// Mass in kilograms (only meaningful for dynamic bodies).
	[Editable("Mass")]
	public float Mass
	{
		get => mMass;
		set
		{
			mMass = Math.Max(value, 0.0f);
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyMass(mBodyHandle, mMass);
		}
	}

	/// Surface friction coefficient.
	[Editable("Friction")]
	public float Friction
	{
		get => mFriction;
		set
		{
			mFriction = value;
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyFriction(mBodyHandle, value);
		}
	}

	/// Restitution (bounciness).
	[Editable("Restitution")]
	public float Restitution
	{
		get => mRestitution;
		set
		{
			mRestitution = value;
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyRestitution(mBodyHandle, value);
		}
	}

	/// Linear velocity damping.
	[Editable("Linear Damping")]
	public float LinearDamping
	{
		get => mLinearDamping;
		set
		{
			mLinearDamping = value;
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyLinearDamping(mBodyHandle, value);
		}
	}

	/// Angular velocity damping.
	[Editable("Angular Damping")]
	public float AngularDamping
	{
		get => mAngularDamping;
		set
		{
			mAngularDamping = value;
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyAngularDamping(mBodyHandle, value);
		}
	}

	/// Gravity scale factor (0 = no gravity, 1 = normal).
	[Editable("Gravity Factor")]
	public float GravityFactor
	{
		get => mGravityFactor;
		set
		{
			mGravityFactor = value;
			if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
				mPhysicsWorld.World.SetBodyGravityFactor(mBodyHandle, value);
		}
	}

	/// Linear velocity of the body.
	public Vector3 LinearVelocity
	{
		get => (mBodyHandle.IsValid && mPhysicsWorld?.World != null) ? mPhysicsWorld.World.GetLinearVelocity(mBodyHandle) : .Zero;
		set { if (mBodyHandle.IsValid && mPhysicsWorld?.World != null) mPhysicsWorld.World.SetLinearVelocity(mBodyHandle, value); }
	}

	/// Angular velocity of the body.
	public Vector3 AngularVelocity
	{
		get => (mBodyHandle.IsValid && mPhysicsWorld?.World != null) ? mPhysicsWorld.World.GetAngularVelocity(mBodyHandle) : .Zero;
		set { if (mBodyHandle.IsValid && mPhysicsWorld?.World != null) mPhysicsWorld.World.SetAngularVelocity(mBodyHandle, value); }
	}

	// ===== Forces & Impulses =====

	/// Applies a continuous force (in Newtons) at center of mass.
	public void AddForce(Vector3 force)
	{
		if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
			mPhysicsWorld.World.AddForce(mBodyHandle, force);
	}

	/// Applies a continuous force at a world position.
	public void AddForceAtPosition(Vector3 force, Vector3 position)
	{
		if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
			mPhysicsWorld.World.AddForceAtPosition(mBodyHandle, force, position);
	}

	/// Applies a torque.
	public void AddTorque(Vector3 torque)
	{
		if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
			mPhysicsWorld.World.AddTorque(mBodyHandle, torque);
	}

	/// Applies an instantaneous impulse at center of mass.
	public void AddImpulse(Vector3 impulse)
	{
		if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
			mPhysicsWorld.World.AddImpulse(mBodyHandle, impulse);
	}

	/// Applies an instantaneous impulse at a world position.
	public void AddImpulseAtPosition(Vector3 impulse, Vector3 position)
	{
		if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
			mPhysicsWorld.World.AddImpulseAtPosition(mBodyHandle, impulse, position);
	}

	/// Wakes the body from sleep.
	public void Activate()
	{
		if (mBodyHandle.IsValid && mPhysicsWorld?.World != null)
			mPhysicsWorld.World.ActivateBody(mBodyHandle);
	}

	// ===== Body Creation =====

	/// Creates the physics body using the CollisionShape on the same node.
	/// The PhysicsWorld must be set in the scene before calling this.
	public Result<void> CreateBody(PhysicsWorld physicsWorld)
	{
		DestroyBody();
		mPhysicsWorld = physicsWorld;

		if (physicsWorld?.World == null)
			return .Err;

		// Find CollisionShape on same node
		CollisionShape shape = null;
		if (Node != null)
		{
			for (let comp in Node.Components)
			{
				if (let s = comp as CollisionShape)
				{
					shape = s;
					break;
				}
			}
		}

		if (shape == null || !shape.IsValid)
			return .Err;

		// Get world transform from node
		let pos = Node != null ? Node.WorldPosition : Vector3.Zero;
		let rot = Node != null ? Node.WorldRotation : Quaternion.Identity;

		var desc = PhysicsBodyDescriptor()
		{
			Shape = shape.ShapeHandle,
			Position = pos,
			Rotation = rot,
			BodyType = mBodyType,
			Mass = mMass,
			Friction = mFriction,
			Restitution = mRestitution,
			LinearDamping = mLinearDamping,
			AngularDamping = mAngularDamping,
			GravityFactor = mGravityFactor,
			AllowSleep = mAllowSleep,
			IsSensor = mIsSensor
		};

		if (physicsWorld.World.CreateBody(desc) case .Ok(let handle))
		{
			mBodyHandle = handle;
			physicsWorld.RegisterBody(handle, this);
			return .Ok;
		}

		return .Err;
	}

	/// Destroys the physics body.
	public void DestroyBody()
	{
		if (mBodyHandle.IsValid && mPhysicsWorld != null)
		{
			mPhysicsWorld.UnregisterBody(mBodyHandle);
			if (mPhysicsWorld.World != null)
				mPhysicsWorld.World.DestroyBody(mBodyHandle);
		}
		mBodyHandle = .Invalid;
	}

	// ===== Transform Synchronization =====

	/// Syncs the node transform FROM the physics body (for dynamic bodies).
	/// Call after physics stepping.
	public void SyncFromPhysics()
	{
		if (!mBodyHandle.IsValid || mPhysicsWorld?.World == null || Node == null)
			return;

		// Only sync dynamic bodies — kinematic/static are driven by the scene
		if (mBodyType != .Dynamic)
			return;

		let pos = mPhysicsWorld.World.GetBodyPosition(mBodyHandle);
		let rot = mPhysicsWorld.World.GetBodyRotation(mBodyHandle);

		Node.WorldPosition = pos;
		Node.WorldRotation = rot;
	}

	/// Syncs the physics body FROM the node transform (for kinematic bodies).
	/// Call before physics stepping.
	public void SyncToPhysics()
	{
		if (!mBodyHandle.IsValid || mPhysicsWorld?.World == null || Node == null)
			return;

		let pos = Node.WorldPosition;
		let rot = Node.WorldRotation;

		mPhysicsWorld.World.SetBodyTransform(mBodyHandle, pos, rot);
	}

	// ===== Lifecycle =====

	protected override void OnTransformChanged()
	{
		// For kinematic bodies, push transform to physics when node moves
		if (mBodyType == .Kinematic && mBodyHandle.IsValid && mPhysicsWorld?.World != null && Node != null)
		{
			SyncToPhysics();
		}
	}

	protected override void OnRemoved()
	{
		DestroyBody();
		mPhysicsWorld = null;
	}
}
