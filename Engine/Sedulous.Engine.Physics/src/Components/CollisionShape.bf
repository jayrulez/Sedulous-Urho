using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Physics;

/// Type of collision shape geometry.
public enum CollisionShapeType
{
	/// Box defined by half-extents.
	Box,
	/// Sphere defined by radius.
	Sphere,
	/// Capsule defined by half-height and radius (aligned along Y axis).
	Capsule,
	/// Cylinder defined by half-height and radius (aligned along Y axis).
	Cylinder,
	/// Infinite plane defined by normal and distance.
	Plane
}

/// Scene component that defines a collision shape for a RigidBody.
///
/// Must be attached to the same node as a RigidBody. When the shape
/// parameters change, the underlying physics shape is recreated and
/// the body is updated. Multiple CollisionShapes on a node are not
/// currently supported — use a compound shape at the physics level.
///
public class CollisionShape : Component
{
	private CollisionShapeType mShapeType = .Box;
	private Vector3 mSize = .(1.0f, 1.0f, 1.0f); // half-extents for box
	private float mRadius = 0.5f;
	private float mHalfHeight = 0.5f;
	private Vector3 mPlaneNormal = .(0, 1, 0);
	private float mPlaneDistance = 0.0f;
	private ShapeHandle mShapeHandle = .Invalid;
	private PhysicsWorld mPhysicsWorld;

	public ~this()
	{
		ReleaseShape();
	}

	// ===== Properties =====

	/// The type of collision shape.
	[Editable("Shape Type")]
	public CollisionShapeType ShapeType
	{
		get => mShapeType;
		set
		{
			if (mShapeType != value)
			{
				mShapeType = value;
				RecreateShape();
			}
		}
	}

	/// Box half-extents (only used when ShapeType == Box).
	[Editable("Size")]
	public Vector3 Size
	{
		get => mSize;
		set
		{
			mSize = value;
			if (mShapeType == .Box) RecreateShape();
		}
	}

	/// Sphere/Capsule/Cylinder radius.
	[Editable("Radius")]
	public float Radius
	{
		get => mRadius;
		set
		{
			mRadius = Math.Max(value, 0.001f);
			if (mShapeType == .Sphere || mShapeType == .Capsule || mShapeType == .Cylinder)
				RecreateShape();
		}
	}

	/// Capsule/Cylinder half-height.
	[Editable("Half Height")]
	public float HalfHeight
	{
		get => mHalfHeight;
		set
		{
			mHalfHeight = Math.Max(value, 0.001f);
			if (mShapeType == .Capsule || mShapeType == .Cylinder)
				RecreateShape();
		}
	}

	/// The underlying physics shape handle.
	public ShapeHandle ShapeHandle => mShapeHandle;

	/// Whether this shape has been successfully created.
	public bool IsValid => mShapeHandle.IsValid;

	// ===== Shape Management =====

	/// Creates the physics shape based on current parameters.
	/// Called automatically when attached to a node with a PhysicsWorld in the scene.
	public void CreateShape(PhysicsWorld physicsWorld)
	{
		ReleaseShape();
		mPhysicsWorld = physicsWorld;

		if (physicsWorld?.World == null)
			return;

		let world = physicsWorld.World;

		switch (mShapeType)
		{
		case .Box:
			if (world.CreateBoxShape(mSize) case .Ok(let h))
				mShapeHandle = h;
		case .Sphere:
			if (world.CreateSphereShape(mRadius) case .Ok(let h))
				mShapeHandle = h;
		case .Capsule:
			if (world.CreateCapsuleShape(mHalfHeight, mRadius) case .Ok(let h))
				mShapeHandle = h;
		case .Cylinder:
			if (world.CreateCylinderShape(mHalfHeight, mRadius) case .Ok(let h))
				mShapeHandle = h;
		case .Plane:
			if (world.CreatePlaneShape(mPlaneNormal, mPlaneDistance) case .Ok(let h))
				mShapeHandle = h;
		}
	}

	/// Releases the current physics shape.
	public void ReleaseShape()
	{
		if (mShapeHandle.IsValid && mPhysicsWorld?.World != null)
		{
			mPhysicsWorld.World.ReleaseShape(mShapeHandle);
		}
		mShapeHandle = .Invalid;
	}

	// ===== Private =====

	private void RecreateShape()
	{
		if (mPhysicsWorld != null)
			CreateShape(mPhysicsWorld);
	}

	protected override void OnRemoved()
	{
		ReleaseShape();
		mPhysicsWorld = null;
	}
}
