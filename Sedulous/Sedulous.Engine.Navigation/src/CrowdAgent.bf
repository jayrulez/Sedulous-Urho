using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Navigation;
using internal Sedulous.Engine.Navigation;

/// Scene component representing a crowd-managed navigation agent.
///
/// Attach to a node to make it follow crowd pathfinding. Requires a
/// CrowdManager in the scene. The agent's position syncs from the
/// crowd simulation to the owning node's world position.
///
public class CrowdAgent : Component
{
	private CrowdManager mCrowdManager;
	private int32 mAgentIndex = -1;

	// Agent parameters
	private float mRadius = 0.6f;
	private float mHeight = 2.0f;
	private float mMaxAcceleration = 8.0f;
	private float mMaxSpeed = 3.5f;
	private Vector3 mTargetPosition = .Zero;
	private bool mHasTarget = false;

	public ~this()
	{
		// Don't call RemoveFromCrowd() here — OnRemoved() already handles it,
		// and during scene teardown the CrowdManager may already be deleted.
		// CrowdManager.Cleanup() clears our reference via ClearCrowdReference().
	}

	// ===== Properties =====

	/// Agent radius.
	[Editable("Radius")]
	public float Radius
	{
		get => mRadius;
		set => mRadius = Math.Max(value, 0.01f);
	}

	/// Agent height.
	[Editable("Height")]
	public float Height
	{
		get => mHeight;
		set => mHeight = Math.Max(value, 0.01f);
	}

	/// Maximum acceleration.
	[Editable("Max Acceleration")]
	public float MaxAcceleration
	{
		get => mMaxAcceleration;
		set => mMaxAcceleration = Math.Max(value, 0.0f);
	}

	/// Maximum speed.
	[Editable("Max Speed")]
	public float MaxSpeed
	{
		get => mMaxSpeed;
		set => mMaxSpeed = Math.Max(value, 0.0f);
	}

	/// Whether this agent is registered with the crowd.
	public bool IsRegistered => mAgentIndex >= 0;

	/// The agent's index in the crowd.
	public int32 AgentIndex => mAgentIndex;

	/// Current position from the crowd simulation.
	public Vector3 CrowdPosition
	{
		get
		{
			if (mCrowdManager != null && mAgentIndex >= 0)
				return mCrowdManager.GetAgentPosition(mAgentIndex);
			return Node?.WorldPosition ?? .Zero;
		}
	}

	/// Current velocity from the crowd simulation.
	public Vector3 Velocity
	{
		get
		{
			if (mCrowdManager != null && mAgentIndex >= 0)
				return mCrowdManager.GetAgentVelocity(mAgentIndex);
			return .Zero;
		}
	}

	// ===== Registration =====

	/// Registers this agent with a CrowdManager.
	public Result<void> Register(CrowdManager crowdManager)
	{
		RemoveFromCrowd();
		mCrowdManager = crowdManager;

		if (crowdManager == null || !crowdManager.IsInitialized)
			return .Err;

		let pos = Node?.WorldPosition ?? .Zero;
		mAgentIndex = crowdManager.AddAgent(pos, mRadius, mHeight, mMaxAcceleration, mMaxSpeed);

		if (mAgentIndex < 0)
			return .Err;

		crowdManager.TrackAgent(this);

		// Apply any pending target
		if (mHasTarget)
			crowdManager.RequestMoveTarget(mAgentIndex, mTargetPosition);

		return .Ok;
	}

	/// Removes this agent from the crowd.
	public void RemoveFromCrowd()
	{
		if (mCrowdManager != null && mAgentIndex >= 0)
		{
			mCrowdManager.RemoveAgent(mAgentIndex);
			mCrowdManager.UntrackAgent(this);
		}
		mAgentIndex = -1;
		mCrowdManager = null;
	}

	/// Called by CrowdManager during its cleanup to prevent dangling references.
	internal void ClearCrowdReference()
	{
		mAgentIndex = -1;
		mCrowdManager = null;
	}

	// ===== Navigation =====

	/// Sets the target position for pathfinding.
	public void SetTargetPosition(Vector3 target)
	{
		mTargetPosition = target;
		mHasTarget = true;

		if (mCrowdManager != null && mAgentIndex >= 0)
			mCrowdManager.RequestMoveTarget(mAgentIndex, target);
	}

	/// Sets a direct movement velocity (overrides pathfinding).
	public void SetVelocity(Vector3 velocity)
	{
		mHasTarget = false;

		if (mCrowdManager != null && mAgentIndex >= 0)
			mCrowdManager.RequestMoveVelocity(mAgentIndex, velocity);
	}

	/// Cancels the current movement target.
	public void Stop()
	{
		mHasTarget = false;
		SetVelocity(.Zero);
	}

	// ===== Synchronization =====

	/// Syncs the node position from the crowd simulation.
	/// Call after CrowdManager.Update().
	public void SyncFromCrowd()
	{
		if (mCrowdManager == null || mAgentIndex < 0 || Node == null)
			return;

		if (!mCrowdManager.IsAgentActive(mAgentIndex))
			return;

		let pos = mCrowdManager.GetAgentPosition(mAgentIndex);
		Node.WorldPosition = pos;
	}

	// ===== Lifecycle =====

	protected override void OnRemoved()
	{
		RemoveFromCrowd();
	}
}
