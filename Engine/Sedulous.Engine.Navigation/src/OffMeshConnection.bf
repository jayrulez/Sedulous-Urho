using System;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using recastnavigation_Beef;

namespace Sedulous.Engine.Navigation;

/// Component representing a manual navigation link between two points.
///
/// Off-mesh connections allow navigation across gaps, ladders, teleporters,
/// or other areas the nav mesh wouldn't normally connect. The connection
/// goes from this node's world position to the endpoint position.
/// NavigationMesh collects these during build to include in the nav mesh data.
///
[EngineComponent("Navigation")]
public class OffMeshConnection : Component
{
	private Node mEndpointNode;
	private Vector3 mEndpointPosition = .Zero;
	private float mRadius = 1.0f;
	private bool mBidirectional = true;
	private uint8 mAreaType = RC_WALKABLE_AREA;
	private uint16 mFlags = 1;
	private uint32 mUserID = 0;

	// ===== Properties =====

	/// The target node for this connection's endpoint.
	/// If set, the endpoint position tracks this node's world position.
	public Node EndpointNode
	{
		get => mEndpointNode;
		set => mEndpointNode = value;
	}

	/// Explicit endpoint position (used when EndpointNode is null).
	public Vector3 EndpointPosition
	{
		get => mEndpointPosition;
		set => mEndpointPosition = value;
	}

	/// The effective endpoint position (from EndpointNode if set, else EndpointPosition).
	public Vector3 EffectiveEndpoint
	{
		get
		{
			if (mEndpointNode != null)
				return mEndpointNode.WorldPosition;
			return mEndpointPosition;
		}
	}

	/// Connection radius — how close an agent must be to use this link.
	[Editable("Radius")]
	public float Radius
	{
		get => mRadius;
		set => mRadius = Math.Max(value, 0.01f);
	}

	/// Whether the connection can be traversed in both directions.
	[Editable("Bidirectional")]
	public bool Bidirectional
	{
		get => mBidirectional;
		set => mBidirectional = value;
	}

	/// Navigation area type for this connection (defaults to walkable).
	public uint8 AreaType
	{
		get => mAreaType;
		set => mAreaType = value;
	}

	/// Navigation polygon flags for this connection.
	public uint16 Flags
	{
		get => mFlags;
		set => mFlags = value;
	}

	/// User-defined ID for identifying this connection.
	public uint32 UserID
	{
		get => mUserID;
		set => mUserID = value;
	}

	/// The start position (this node's world position).
	public Vector3 StartPosition => Node?.WorldPosition ?? .Zero;
}
