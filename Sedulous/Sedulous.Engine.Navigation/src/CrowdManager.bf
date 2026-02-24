using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using recastnavigation_Beef;

namespace Sedulous.Engine.Navigation;

/// Scene component that manages crowd-based pathfinding and local avoidance.
///
/// Wraps Detour's dtCrowd. Requires a NavigationMesh on the same scene.
/// CrowdAgent components register themselves with this manager.
///
public class CrowdManager : Component
{
	private dtCrowdHandle mCrowd;
	private dtNavMeshQueryHandle mNavQuery;
	private int32 mMaxAgents = 128;
	private float mMaxAgentRadius = 2.0f;
	private NavigationMesh mNavMesh;

	public ~this()
	{
		Cleanup();
	}

	// ===== Properties =====

	/// Maximum number of agents this crowd can manage.
	[Editable("Max Agents")]
	public int32 MaxAgents
	{
		get => mMaxAgents;
		set => mMaxAgents = Math.Max(value, 1);
	}

	/// Maximum agent radius (used for crowd initialization).
	[Editable("Max Agent Radius")]
	public float MaxAgentRadius
	{
		get => mMaxAgentRadius;
		set => mMaxAgentRadius = Math.Max(value, 0.1f);
	}

	/// Whether the crowd has been initialized.
	public bool IsInitialized => mCrowd != null;

	/// The underlying Detour crowd handle.
	public dtCrowdHandle CrowdHandle => mCrowd;

	// ===== Initialization =====

	/// Initializes the crowd with the given navigation mesh.
	public Result<void> Initialize(NavigationMesh navMesh)
	{
		Cleanup();
		mNavMesh = navMesh;

		if (navMesh == null || !navMesh.IsBuilt || navMesh.NavMeshHandle == null)
			return .Err;

		mCrowd = dtAllocCrowd();
		if (mCrowd == null)
			return .Err;

		if (dtCrowdInit(mCrowd, mMaxAgents, mMaxAgentRadius, navMesh.NavMeshHandle) == 0)
		{
			dtFreeCrowd(mCrowd);
			mCrowd = null;
			return .Err;
		}

		// Create a query for finding nearest polys (for move targets)
		mNavQuery = dtAllocNavMeshQuery();
		if (mNavQuery != null)
			dtNavMeshQueryInit(mNavQuery, navMesh.NavMeshHandle, 2048);

		return .Ok;
	}

	// ===== Agent Management =====

	/// Adds an agent to the crowd at the given position.
	/// Returns the agent index, or -1 on failure.
	public int32 AddAgent(Vector3 position, float radius, float height, float maxAcceleration, float maxSpeed)
	{
		if (mCrowd == null)
			return -1;

		float[3] pos = .(position.X, position.Y, position.Z);

		var agentParams = dtCrowdAgentParams();
		agentParams.radius = radius;
		agentParams.height = height;
		agentParams.maxAcceleration = maxAcceleration;
		agentParams.maxSpeed = maxSpeed;
		agentParams.collisionQueryRange = radius * 12.0f;
		agentParams.pathOptimizationRange = radius * 30.0f;
		agentParams.separationWeight = 2.0f;
		agentParams.updateFlags = (uint8)(
			(int32)dtCrowdUpdateFlags.DT_CROWD_ANTICIPATE_TURNS |
			(int32)dtCrowdUpdateFlags.DT_CROWD_OBSTACLE_AVOIDANCE |
			(int32)dtCrowdUpdateFlags.DT_CROWD_SEPARATION |
			(int32)dtCrowdUpdateFlags.DT_CROWD_OPTIMIZE_VIS |
			(int32)dtCrowdUpdateFlags.DT_CROWD_OPTIMIZE_TOPO
		);
		agentParams.obstacleAvoidanceType = 3;
		agentParams.queryFilterType = 0;
		agentParams.userData = null;

		return dtCrowdAddAgent(mCrowd, &pos, &agentParams);
	}

	/// Removes an agent from the crowd.
	public void RemoveAgent(int32 agentIndex)
	{
		if (mCrowd != null && agentIndex >= 0)
			dtCrowdRemoveAgent(mCrowd, agentIndex);
	}

	/// Sets the move target for an agent.
	public bool RequestMoveTarget(int32 agentIndex, Vector3 target)
	{
		if (mCrowd == null || agentIndex < 0 || mNavMesh == null || mNavQuery == null)
			return false;

		float[3] targetPos = .(target.X, target.Y, target.Z);

		let filter = dtCrowdGetFilter(mCrowd, 0);
		if (filter == null)
			return false;

		dtPolyRef targetRef = 0;
		float[3] nearest = .();
		float[3] queryExtents = .();
		dtCrowdGetQueryHalfExtents(mCrowd, &queryExtents);

		dtNavMeshQueryFindNearestPoly(mNavQuery, &targetPos, &queryExtents, filter, &targetRef, &nearest);

		if (targetRef == 0)
			return false;

		return dtCrowdRequestMoveTarget(mCrowd, agentIndex, targetRef, &nearest) != 0;
	}

	/// Sets the move velocity for an agent directly.
	public bool RequestMoveVelocity(int32 agentIndex, Vector3 velocity)
	{
		if (mCrowd == null || agentIndex < 0)
			return false;

		float[3] vel = .(velocity.X, velocity.Y, velocity.Z);
		return dtCrowdRequestMoveVelocity(mCrowd, agentIndex, &vel) != 0;
	}

	/// Gets the current position of an agent.
	public Vector3 GetAgentPosition(int32 agentIndex)
	{
		if (mCrowd == null || agentIndex < 0)
			return .Zero;

		float[3] pos = .();
		dtCrowdAgentGetPosition(mCrowd, agentIndex, &pos);
		return Vector3(pos[0], pos[1], pos[2]);
	}

	/// Gets the current velocity of an agent.
	public Vector3 GetAgentVelocity(int32 agentIndex)
	{
		if (mCrowd == null || agentIndex < 0)
			return .Zero;

		float[3] vel = .();
		dtCrowdAgentGetVelocity(mCrowd, agentIndex, &vel);
		return Vector3(vel[0], vel[1], vel[2]);
	}

	/// Returns whether an agent is active.
	public bool IsAgentActive(int32 agentIndex)
	{
		if (mCrowd == null || agentIndex < 0)
			return false;

		return dtCrowdAgentIsActive(mCrowd, agentIndex) != 0;
	}

	// ===== Simulation =====

	/// Steps the crowd simulation.
	/// Call once per frame with the frame delta time.
	public void Update(float deltaTime)
	{
		if (mCrowd == null)
			return;

		dtCrowdUpdate(mCrowd, deltaTime, null);
	}

	// ===== Private =====

	private void Cleanup()
	{
		if (mNavQuery != null)
		{
			dtFreeNavMeshQuery(mNavQuery);
			mNavQuery = null;
		}

		if (mCrowd != null)
		{
			dtFreeCrowd(mCrowd);
			mCrowd = null;
		}
		mNavMesh = null;
	}

	protected override void OnRemoved()
	{
		Cleanup();
	}
}
