using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Physics;

/// Scene component that wraps an IPhysicsWorld for physics simulation.
///
/// Attach to the Scene root node to enable physics. Steps the simulation
/// using a fixed timestep with accumulator pattern during scene updates.
/// Provides raycast/shapecast proxy methods.
///
/// In Urho3D, PhysicsWorld is the equivalent of the "PhysicsWorld" subsystem
/// that owns Bullet's btDiscreteDynamicsWorld. Here we wrap Sedulous's
/// IPhysicsWorld (Jolt backend).
///
public class PhysicsWorld : Component
{
	private IPhysicsWorld mWorld;
	private bool mOwnsWorld;
	private float mFixedTimeStep = 1.0f / 60.0f;
	private int32 mMaxSubSteps = 8;
	private float mAccumulator = 0.0f;
	private bool mSimulationEnabled = true;

	// Tracked bodies — RigidBody components register here for sync and queries
	private Dictionary<BodyHandle, Component> mTrackedBodies = new .() ~ delete _;

	public ~this()
	{
		if (mOwnsWorld && mWorld != null)
			delete mWorld;
	}

	// ===== Properties =====

	/// The underlying physics world.
	public IPhysicsWorld World => mWorld;

	/// World gravity vector.
	public Vector3 Gravity
	{
		get => mWorld != null ? mWorld.Gravity : .(0, -9.81f, 0);
		set { if (mWorld != null) mWorld.Gravity = value; }
	}

	/// Fixed timestep for physics simulation (default: 1/60).
	[Editable("Fixed Time Step")]
	public float FixedTimeStep
	{
		get => mFixedTimeStep;
		set => mFixedTimeStep = Math.Max(value, 0.001f);
	}

	/// Maximum sub-steps per frame to prevent spiral of death.
	[Editable("Max Sub Steps")]
	public int32 MaxSubSteps
	{
		get => mMaxSubSteps;
		set => mMaxSubSteps = Math.Max(value, 1);
	}

	/// Whether physics simulation is running.
	[Editable("Simulation Enabled")]
	public bool SimulationEnabled
	{
		get => mSimulationEnabled;
		set => mSimulationEnabled = value;
	}

	/// Number of active bodies in the physics world.
	public uint32 ActiveBodyCount => mWorld != null ? mWorld.ActiveBodyCount : 0;

	/// Total number of bodies in the physics world.
	public uint32 BodyCount => mWorld != null ? mWorld.BodyCount : 0;

	// ===== Initialization =====

	/// Sets an externally created physics world.
	/// If own is true, this component will delete the world on destruction.
	public void SetWorld(IPhysicsWorld world, bool own = false)
	{
		if (mOwnsWorld && mWorld != null)
			delete mWorld;

		mWorld = world;
		mOwnsWorld = own;
	}

	// ===== Simulation =====

	/// Steps the physics simulation by deltaTime using fixed timestep accumulation.
	/// Call this once per frame from the scene update.
	public void StepSimulation(float deltaTime)
	{
		if (mWorld == null || !mSimulationEnabled)
			return;

		mAccumulator += deltaTime;

		int32 steps = 0;
		while (mAccumulator >= mFixedTimeStep && steps < mMaxSubSteps)
		{
			mWorld.Step(mFixedTimeStep);
			mAccumulator -= mFixedTimeStep;
			steps++;
		}

		// Clamp excess to prevent spiral of death
		if (mAccumulator > mFixedTimeStep)
			mAccumulator = mFixedTimeStep;
	}

	/// Returns the interpolation factor (0..1) for rendering between physics steps.
	public float InterpolationFactor
	{
		get => mFixedTimeStep > 0 ? mAccumulator / mFixedTimeStep : 0;
	}

	// ===== Queries: Raycasting =====

	/// Casts a ray and returns the closest hit.
	public bool RayCast(Vector3 origin, Vector3 direction, float maxDistance, out RayCastResult result)
	{
		if (mWorld == null)
		{
			result = default;
			return false;
		}

		let query = RayCastQuery(origin, direction, maxDistance);
		return mWorld.RayCast(query, out result);
	}

	/// Casts a ray and returns the closest hit, with layer filtering.
	public bool RayCast(Vector3 origin, Vector3 direction, float maxDistance, uint32 layerMask, out RayCastResult result)
	{
		if (mWorld == null)
		{
			result = default;
			return false;
		}

		var query = RayCastQuery(origin, direction, maxDistance);
		query.LayerMask = layerMask;
		return mWorld.RayCast(query, out result);
	}

	/// Casts a ray and returns all hits.
	public void RayCastAll(Vector3 origin, Vector3 direction, float maxDistance, List<RayCastResult> results)
	{
		if (mWorld == null)
			return;

		let query = RayCastQuery(origin, direction, maxDistance);
		mWorld.RayCastAll(query, results);
	}

	// ===== Queries: Shape Casting =====

	/// Casts a shape along a direction and returns the closest hit.
	public bool ShapeCast(ShapeHandle shape, Vector3 position, Quaternion rotation,
		Vector3 direction, float maxDistance, out ShapeCastResult result)
	{
		if (mWorld == null)
		{
			result = default;
			return false;
		}

		let query = ShapeCastQuery(shape, position, rotation, direction, maxDistance);
		return mWorld.ShapeCast(query, out result);
	}

	/// Casts a shape along a direction and returns all hits.
	public void ShapeCastAll(ShapeHandle shape, Vector3 position, Quaternion rotation,
		Vector3 direction, float maxDistance, List<ShapeCastResult> results)
	{
		if (mWorld == null)
			return;

		let query = ShapeCastQuery(shape, position, rotation, direction, maxDistance);
		mWorld.ShapeCastAll(query, results);
	}

	// ===== Shape Creation (convenience proxies) =====

	/// Creates a sphere collision shape.
	public Result<ShapeHandle> CreateSphereShape(float radius)
	{
		if (mWorld == null) return .Err;
		return mWorld.CreateSphereShape(radius);
	}

	/// Creates a box collision shape.
	public Result<ShapeHandle> CreateBoxShape(Vector3 halfExtents)
	{
		if (mWorld == null) return .Err;
		return mWorld.CreateBoxShape(halfExtents);
	}

	/// Creates a capsule collision shape.
	public Result<ShapeHandle> CreateCapsuleShape(float halfHeight, float radius)
	{
		if (mWorld == null) return .Err;
		return mWorld.CreateCapsuleShape(halfHeight, radius);
	}

	/// Creates a cylinder collision shape.
	public Result<ShapeHandle> CreateCylinderShape(float halfHeight, float radius)
	{
		if (mWorld == null) return .Err;
		return mWorld.CreateCylinderShape(halfHeight, radius);
	}

	/// Releases a collision shape.
	public void ReleaseShape(ShapeHandle handle)
	{
		if (mWorld != null)
			mWorld.ReleaseShape(handle);
	}

	// ===== Body Tracking =====

	/// Registers a body with this physics world for tracking.
	/// Called by RigidBody components when they create their physics body.
	public void RegisterBody(BodyHandle handle, Component owner)
	{
		mTrackedBodies[handle] = owner;
	}

	/// Unregisters a tracked body.
	/// Called by RigidBody components when they destroy their physics body.
	public void UnregisterBody(BodyHandle handle)
	{
		mTrackedBodies.Remove(handle);
	}

	/// Finds the component that owns a body handle.
	public Component FindBodyOwner(BodyHandle handle)
	{
		if (mTrackedBodies.TryGetValue(handle, let owner))
			return owner;
		return null;
	}

	/// Gets all tracked body handles.
	public Dictionary<BodyHandle, Component>.Enumerator TrackedBodies => mTrackedBodies.GetEnumerator();

	// ===== Event Listeners =====

	/// Sets the contact listener for collision callbacks.
	public void SetContactListener(IContactListener listener)
	{
		if (mWorld != null)
			mWorld.SetContactListener(listener);
	}

	/// Sets the body activation listener.
	public void SetBodyActivationListener(IBodyActivationListener listener)
	{
		if (mWorld != null)
			mWorld.SetBodyActivationListener(listener);
	}

	// ===== Lifecycle =====

	protected override void OnSceneSet(Scene scene)
	{
		// Optimize broad phase when added to scene
		if (scene != null && mWorld != null)
			mWorld.OptimizeBroadPhase();
	}

	protected override void OnRemoved()
	{
		// Disconnect all tracked RigidBody and their CollisionShape components
		// so they don't try to access this PhysicsWorld during scene teardown
		// (PhysicsWorld is destroyed before child node components).
		for (let kv in mTrackedBodies)
		{
			if (let rb = kv.value as RigidBody)
			{
				rb.[Friend]mBodyHandle = .Invalid;
				rb.[Friend]mPhysicsWorld = null;

				// Also disconnect the CollisionShape on the same node
				if (rb.Node != null)
				{
					for (let comp in rb.Node.Components)
					{
						if (let cs = comp as CollisionShape)
						{
							cs.[Friend]mShapeHandle = .Invalid;
							cs.[Friend]mPhysicsWorld = null;
						}
					}
				}
			}
		}
		mTrackedBodies.Clear();
	}
}
