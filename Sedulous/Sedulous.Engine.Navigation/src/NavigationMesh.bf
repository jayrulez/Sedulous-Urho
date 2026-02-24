using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Engine.Core;
using recastnavigation_Beef;

namespace Sedulous.Engine.Navigation;

/// Result of a navigation mesh raycast.
public struct NavRaycastResult
{
	/// The hit position (end of ray if no hit).
	public Vector3 Position;
	/// The hit normal.
	public Vector3 Normal;
	/// Distance fraction along the ray (1.0 if no hit).
	public float Fraction;
	/// Whether the ray hit a boundary.
	public bool HasHit;
}

/// Build configuration for the navigation mesh.
public struct NavMeshBuildSettings
{
	/// Cell size in world units (xz plane). Smaller = more detail, slower.
	public float CellSize = 0.3f;
	/// Cell height in world units (y axis).
	public float CellHeight = 0.2f;
	/// Maximum slope angle in degrees that an agent can walk on.
	public float AgentMaxSlope = 45.0f;
	/// Agent height in world units.
	public float AgentHeight = 2.0f;
	/// Agent radius in world units.
	public float AgentRadius = 0.6f;
	/// Maximum ledge height the agent can climb.
	public float AgentMaxClimb = 0.9f;
	/// Maximum edge length for the nav mesh polygons.
	public float MaxEdgeLength = 12.0f;
	/// Maximum error for edge simplification.
	public float MaxSimplificationError = 1.3f;
	/// Minimum region area (in cell count) to keep.
	public int32 MinRegionArea = 8;
	/// Regions smaller than this merge into larger regions.
	public int32 MergeRegionArea = 20;
	/// Maximum vertices per polygon.
	public int32 MaxVertsPerPoly = 6;
	/// Detail mesh sample distance.
	public float DetailSampleDist = 6.0f;
	/// Detail mesh max sample error.
	public float DetailSampleMaxError = 1.0f;
}

/// Scene component that wraps Recast/Detour navigation mesh.
///
/// Builds a navigation mesh from triangle geometry using the Recast pipeline,
/// then provides pathfinding queries via Detour. Attach to the scene root.
///
public class NavigationMesh : Component
{
	private dtNavMeshHandle mNavMesh;
	private dtNavMeshQueryHandle mNavQuery;
	private dtQueryFilterHandle mQueryFilter;
	private NavMeshBuildSettings mSettings = .();
	private bool mIsBuilt = false;
	private int32 mMaxQueryNodes = 2048;

	public ~this()
	{
		Cleanup();
	}

	// ===== Properties =====

	/// Build settings for the navigation mesh.
	public ref NavMeshBuildSettings Settings => ref mSettings;

	/// Whether the nav mesh has been built.
	public bool IsBuilt => mIsBuilt;

	/// Cell size in world units.
	[Editable("Cell Size")]
	public float CellSize
	{
		get => mSettings.CellSize;
		set => mSettings.CellSize = Math.Max(value, 0.01f);
	}

	/// Cell height in world units.
	[Editable("Cell Height")]
	public float CellHeight
	{
		get => mSettings.CellHeight;
		set => mSettings.CellHeight = Math.Max(value, 0.01f);
	}

	/// Agent height in world units.
	[Editable("Agent Height")]
	public float AgentHeight
	{
		get => mSettings.AgentHeight;
		set => mSettings.AgentHeight = Math.Max(value, 0.01f);
	}

	/// Agent radius in world units.
	[Editable("Agent Radius")]
	public float AgentRadius
	{
		get => mSettings.AgentRadius;
		set => mSettings.AgentRadius = Math.Max(value, 0.0f);
	}

	/// Maximum slope in degrees.
	[Editable("Agent Max Slope")]
	public float AgentMaxSlope
	{
		get => mSettings.AgentMaxSlope;
		set => mSettings.AgentMaxSlope = Math.Clamp(value, 0.0f, 90.0f);
	}

	/// Maximum climb height.
	[Editable("Agent Max Climb")]
	public float AgentMaxClimb
	{
		get => mSettings.AgentMaxClimb;
		set => mSettings.AgentMaxClimb = Math.Max(value, 0.0f);
	}

	// ===== Building =====

	/// Builds the navigation mesh from triangle soup.
	/// vertices: positions as x,y,z triples.
	/// indices: triangle indices (groups of 3).
	/// bounds: world-space bounding box of the geometry.
	public Result<void> Build(Span<float> vertices, Span<int32> indices, BoundingBox bounds)
	{
		Cleanup();

		let numVerts = vertices.Length / 3;
		let numTris = indices.Length / 3;

		if (numVerts == 0 || numTris == 0)
			return .Err;

		// Create Recast context
		let ctx = rcCreateContext(0, 0);
		if (ctx == null)
			return .Err;
		defer rcDestroyContext(ctx);

		// Configure
		var cfg = rcConfig();
		cfg.cs = mSettings.CellSize;
		cfg.ch = mSettings.CellHeight;
		cfg.walkableSlopeAngle = mSettings.AgentMaxSlope;
		cfg.walkableHeight = (int32)Math.Ceiling(mSettings.AgentHeight / cfg.ch);
		cfg.walkableClimb = (int32)Math.Floor(mSettings.AgentMaxClimb / cfg.ch);
		cfg.walkableRadius = (int32)Math.Ceiling(mSettings.AgentRadius / cfg.cs);
		cfg.maxEdgeLen = (int32)(mSettings.MaxEdgeLength / cfg.cs);
		cfg.maxSimplificationError = mSettings.MaxSimplificationError;
		cfg.minRegionArea = mSettings.MinRegionArea;
		cfg.mergeRegionArea = mSettings.MergeRegionArea;
		cfg.maxVertsPerPoly = mSettings.MaxVertsPerPoly;
		cfg.detailSampleDist = mSettings.DetailSampleDist < 0.9f ? 0 : mSettings.CellSize * mSettings.DetailSampleDist;
		cfg.detailSampleMaxError = mSettings.CellHeight * mSettings.DetailSampleMaxError;

		cfg.bmin = .(bounds.Min.X, bounds.Min.Y, bounds.Min.Z);
		cfg.bmax = .(bounds.Max.X, bounds.Max.Y, bounds.Max.Z);

		rcCalcGridSize(&cfg.bmin, &cfg.bmax, cfg.cs, &cfg.width, &cfg.height);

		// Step 1: Create heightfield
		let solid = rcAllocHeightfield();
		if (solid == null) return .Err;
		defer rcFreeHeightField(solid);

		if (rcCreateHeightfield(ctx, solid, cfg.width, cfg.height, &cfg.bmin, &cfg.bmax, cfg.cs, cfg.ch) == 0)
			return .Err;

		// Mark walkable triangles
		let triAreas = new uint8[numTris];
		defer delete triAreas;
		rcMarkWalkableTriangles(ctx, cfg.walkableSlopeAngle, vertices.Ptr, (int32)numVerts, indices.Ptr, (int32)numTris, triAreas.CArray());

		// Rasterize triangles
		if (rcRasterizeTriangles(ctx, vertices.Ptr, (int32)numVerts, indices.Ptr, triAreas.CArray(), (int32)numTris, solid, cfg.walkableClimb) == 0)
			return .Err;

		// Step 2: Filter walkable surfaces
		rcFilterLowHangingWalkableObstacles(ctx, cfg.walkableClimb, solid);
		rcFilterLedgeSpans(ctx, cfg.walkableHeight, cfg.walkableClimb, solid);
		rcFilterWalkableLowHeightSpans(ctx, cfg.walkableHeight, solid);

		// Step 3: Build compact heightfield
		let chf = rcAllocCompactHeightfield();
		if (chf == null) return .Err;
		defer rcFreeCompactHeightfield(chf);

		if (rcBuildCompactHeightfield(ctx, cfg.walkableHeight, cfg.walkableClimb, solid, chf) == 0)
			return .Err;

		// Step 4: Erode walkable area
		if (rcErodeWalkableArea(ctx, cfg.walkableRadius, chf) == 0)
			return .Err;

		// Step 5: Build distance field and regions
		if (rcBuildDistanceField(ctx, chf) == 0)
			return .Err;
		if (rcBuildRegions(ctx, chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea) == 0)
			return .Err;

		// Step 6: Build contours
		let cset = rcAllocContourSet();
		if (cset == null) return .Err;
		defer rcFreeContourSet(cset);

		if (rcBuildContours(ctx, chf, cfg.maxSimplificationError, cfg.maxEdgeLen, cset, (int32)rcBuildContoursFlags.RC_CONTOUR_TESS_WALL_EDGES) == 0)
			return .Err;

		// Step 7: Build polygon mesh
		let pmesh = rcAllocPolyMesh();
		if (pmesh == null) return .Err;
		defer rcFreePolyMesh(pmesh);

		if (rcBuildPolyMesh(ctx, cset, cfg.maxVertsPerPoly, pmesh) == 0)
			return .Err;

		// Step 8: Build detail mesh
		let dmesh = rcAllocPolyMeshDetail();
		if (dmesh == null) return .Err;
		defer rcFreePolyMeshDetail(dmesh);

		if (rcBuildPolyMeshDetail(ctx, pmesh, chf, cfg.detailSampleDist, cfg.detailSampleMaxError, dmesh) == 0)
			return .Err;

		// Step 9: Create Detour navmesh data
		let numPolys = rcPolyMeshGetNPolys(pmesh);
		if (numPolys == 0)
			return .Err;

		// Mark all polys as walkable
		let polyFlags = rcPolyMeshGetFlags(pmesh);
		let polyAreas = rcPolyMeshGetAreas(pmesh);
		for (int32 i = 0; i < numPolys; i++)
		{
			if (polyAreas[i] == RC_WALKABLE_AREA)
			{
				polyFlags[i] = 1; // walkable flag
			}
		}

		var createParams = dtNavMeshCreateParams();
		createParams.verts = rcPolyMeshGetVerts(pmesh);
		createParams.vertCount = rcPolyMeshGetNVerts(pmesh);
		createParams.polys = rcPolyMeshGetPolys(pmesh);
		createParams.polyFlags = rcPolyMeshGetFlags(pmesh);
		createParams.polyAreas = rcPolyMeshGetAreas(pmesh);
		createParams.polyCount = numPolys;
		createParams.nvp = rcPolyMeshGetNvp(pmesh);
		createParams.detailMeshes = rcPolyMeshDetailGetMeshes(dmesh);
		createParams.detailVerts = rcPolyMeshDetailGetVerts(dmesh);
		createParams.detailVertsCount = rcPolyMeshDetailGetNVerts(dmesh);
		createParams.detailTris = rcPolyMeshDetailGetTris(dmesh);
		createParams.detailTriCount = rcPolyMeshDetailGetNTris(dmesh);
		createParams.walkableHeight = mSettings.AgentHeight;
		createParams.walkableRadius = mSettings.AgentRadius;
		createParams.walkableClimb = mSettings.AgentMaxClimb;
		createParams.cs = cfg.cs;
		createParams.ch = cfg.ch;
		createParams.buildBvTree = 1;
		rcPolyMeshGetBMin(pmesh, &createParams.bmin);
		rcPolyMeshGetBMax(pmesh, &createParams.bmax);

		uint8* navData = null;
		int32 navDataSize = 0;
		if (dtCreateNavMeshData(&createParams, &navData, &navDataSize) == 0)
			return .Err;

		// Step 10: Initialize Detour nav mesh
		mNavMesh = dtAllocNavMesh();
		if (mNavMesh == null)
		{
			dtFree(navData);
			return .Err;
		}

		let status = dtNavMeshInitSingle(mNavMesh, navData, navDataSize, (int32)dtTileFlags.DT_TILE_FREE_DATA);
		if (dtStatusFailed(status) != 0)
		{
			dtFree(navData);
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
			return .Err;
		}

		// Step 11: Create query object
		mNavQuery = dtAllocNavMeshQuery();
		if (mNavQuery == null)
		{
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
			return .Err;
		}

		let queryStatus = dtNavMeshQueryInit(mNavQuery, mNavMesh, mMaxQueryNodes);
		if (dtStatusFailed(queryStatus) != 0)
		{
			dtFreeNavMeshQuery(mNavQuery);
			mNavQuery = null;
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
			return .Err;
		}

		// Create default filter
		mQueryFilter = dtAllocQueryFilter();
		if (mQueryFilter != null)
		{
			dtQueryFilterSetIncludeFlags(mQueryFilter, 0xFFFF);
			dtQueryFilterSetExcludeFlags(mQueryFilter, 0);
		}

		mIsBuilt = true;
		return .Ok;
	}

	/// Builds the navigation mesh from triangle soup with off-mesh connections.
	/// offMeshConnections: list of OffMeshConnection components to include.
	public Result<void> Build(Span<float> vertices, Span<int32> indices, BoundingBox bounds, List<OffMeshConnection> offMeshConnections)
	{
		Cleanup();

		let numVerts = vertices.Length / 3;
		let numTris = indices.Length / 3;

		if (numVerts == 0 || numTris == 0)
			return .Err;

		// Create Recast context
		let ctx = rcCreateContext(0, 0);
		if (ctx == null)
			return .Err;
		defer rcDestroyContext(ctx);

		// Configure
		var cfg = rcConfig();
		cfg.cs = mSettings.CellSize;
		cfg.ch = mSettings.CellHeight;
		cfg.walkableSlopeAngle = mSettings.AgentMaxSlope;
		cfg.walkableHeight = (int32)Math.Ceiling(mSettings.AgentHeight / cfg.ch);
		cfg.walkableClimb = (int32)Math.Floor(mSettings.AgentMaxClimb / cfg.ch);
		cfg.walkableRadius = (int32)Math.Ceiling(mSettings.AgentRadius / cfg.cs);
		cfg.maxEdgeLen = (int32)(mSettings.MaxEdgeLength / cfg.cs);
		cfg.maxSimplificationError = mSettings.MaxSimplificationError;
		cfg.minRegionArea = mSettings.MinRegionArea;
		cfg.mergeRegionArea = mSettings.MergeRegionArea;
		cfg.maxVertsPerPoly = mSettings.MaxVertsPerPoly;
		cfg.detailSampleDist = mSettings.DetailSampleDist < 0.9f ? 0 : mSettings.CellSize * mSettings.DetailSampleDist;
		cfg.detailSampleMaxError = mSettings.CellHeight * mSettings.DetailSampleMaxError;

		cfg.bmin = .(bounds.Min.X, bounds.Min.Y, bounds.Min.Z);
		cfg.bmax = .(bounds.Max.X, bounds.Max.Y, bounds.Max.Z);

		rcCalcGridSize(&cfg.bmin, &cfg.bmax, cfg.cs, &cfg.width, &cfg.height);

		// Step 1: Create heightfield
		let solid = rcAllocHeightfield();
		if (solid == null) return .Err;
		defer rcFreeHeightField(solid);

		if (rcCreateHeightfield(ctx, solid, cfg.width, cfg.height, &cfg.bmin, &cfg.bmax, cfg.cs, cfg.ch) == 0)
			return .Err;

		// Mark walkable triangles
		let triAreas = new uint8[numTris];
		defer delete triAreas;
		rcMarkWalkableTriangles(ctx, cfg.walkableSlopeAngle, vertices.Ptr, (int32)numVerts, indices.Ptr, (int32)numTris, triAreas.CArray());

		// Rasterize triangles
		if (rcRasterizeTriangles(ctx, vertices.Ptr, (int32)numVerts, indices.Ptr, triAreas.CArray(), (int32)numTris, solid, cfg.walkableClimb) == 0)
			return .Err;

		// Step 2: Filter walkable surfaces
		rcFilterLowHangingWalkableObstacles(ctx, cfg.walkableClimb, solid);
		rcFilterLedgeSpans(ctx, cfg.walkableHeight, cfg.walkableClimb, solid);
		rcFilterWalkableLowHeightSpans(ctx, cfg.walkableHeight, solid);

		// Step 3: Build compact heightfield
		let chf = rcAllocCompactHeightfield();
		if (chf == null) return .Err;
		defer rcFreeCompactHeightfield(chf);

		if (rcBuildCompactHeightfield(ctx, cfg.walkableHeight, cfg.walkableClimb, solid, chf) == 0)
			return .Err;

		// Step 4: Erode walkable area
		if (rcErodeWalkableArea(ctx, cfg.walkableRadius, chf) == 0)
			return .Err;

		// Step 5: Build distance field and regions
		if (rcBuildDistanceField(ctx, chf) == 0)
			return .Err;
		if (rcBuildRegions(ctx, chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea) == 0)
			return .Err;

		// Step 6: Build contours
		let cset = rcAllocContourSet();
		if (cset == null) return .Err;
		defer rcFreeContourSet(cset);

		if (rcBuildContours(ctx, chf, cfg.maxSimplificationError, cfg.maxEdgeLen, cset, (int32)rcBuildContoursFlags.RC_CONTOUR_TESS_WALL_EDGES) == 0)
			return .Err;

		// Step 7: Build polygon mesh
		let pmesh = rcAllocPolyMesh();
		if (pmesh == null) return .Err;
		defer rcFreePolyMesh(pmesh);

		if (rcBuildPolyMesh(ctx, cset, cfg.maxVertsPerPoly, pmesh) == 0)
			return .Err;

		// Step 8: Build detail mesh
		let dmesh = rcAllocPolyMeshDetail();
		if (dmesh == null) return .Err;
		defer rcFreePolyMeshDetail(dmesh);

		if (rcBuildPolyMeshDetail(ctx, pmesh, chf, cfg.detailSampleDist, cfg.detailSampleMaxError, dmesh) == 0)
			return .Err;

		// Step 9: Create Detour navmesh data
		let numPolys = rcPolyMeshGetNPolys(pmesh);
		if (numPolys == 0)
			return .Err;

		// Mark all polys as walkable
		let polyFlags = rcPolyMeshGetFlags(pmesh);
		let polyAreas = rcPolyMeshGetAreas(pmesh);
		for (int32 i = 0; i < numPolys; i++)
		{
			if (polyAreas[i] == RC_WALKABLE_AREA)
			{
				polyFlags[i] = 1; // walkable flag
			}
		}

		var createParams = dtNavMeshCreateParams();
		createParams.verts = rcPolyMeshGetVerts(pmesh);
		createParams.vertCount = rcPolyMeshGetNVerts(pmesh);
		createParams.polys = rcPolyMeshGetPolys(pmesh);
		createParams.polyFlags = rcPolyMeshGetFlags(pmesh);
		createParams.polyAreas = rcPolyMeshGetAreas(pmesh);
		createParams.polyCount = numPolys;
		createParams.nvp = rcPolyMeshGetNvp(pmesh);
		createParams.detailMeshes = rcPolyMeshDetailGetMeshes(dmesh);
		createParams.detailVerts = rcPolyMeshDetailGetVerts(dmesh);
		createParams.detailVertsCount = rcPolyMeshDetailGetNVerts(dmesh);
		createParams.detailTris = rcPolyMeshDetailGetTris(dmesh);
		createParams.detailTriCount = rcPolyMeshDetailGetNTris(dmesh);
		createParams.walkableHeight = mSettings.AgentHeight;
		createParams.walkableRadius = mSettings.AgentRadius;
		createParams.walkableClimb = mSettings.AgentMaxClimb;
		createParams.cs = cfg.cs;
		createParams.ch = cfg.ch;
		createParams.buildBvTree = 1;
		rcPolyMeshGetBMin(pmesh, &createParams.bmin);
		rcPolyMeshGetBMax(pmesh, &createParams.bmax);

		// Add off-mesh connections
		int32 omConCount = 0;
		float* omVerts = null;
		float* omRad = null;
		uint16* omFlags = null;
		uint8* omAreas = null;
		uint8* omDir = null;
		uint32* omUserID = null;

		defer
		{
			delete omVerts;
			delete omRad;
			delete omFlags;
			delete omAreas;
			delete omDir;
			delete omUserID;
		}

		if (offMeshConnections != null && offMeshConnections.Count > 0)
		{
			omConCount = (int32)offMeshConnections.Count;
			omVerts = new float[omConCount * 6]*;
			omRad = new float[omConCount]*;
			omFlags = new uint16[omConCount]*;
			omAreas = new uint8[omConCount]*;
			omDir = new uint8[omConCount]*;
			omUserID = new uint32[omConCount]*;

			for (int32 i = 0; i < omConCount; i++)
			{
				let con = offMeshConnections[i];
				let startPos = con.StartPosition;
				let endPos = con.EffectiveEndpoint;

				omVerts[i * 6 + 0] = startPos.X;
				omVerts[i * 6 + 1] = startPos.Y;
				omVerts[i * 6 + 2] = startPos.Z;
				omVerts[i * 6 + 3] = endPos.X;
				omVerts[i * 6 + 4] = endPos.Y;
				omVerts[i * 6 + 5] = endPos.Z;
				omRad[i] = con.Radius;
				omFlags[i] = con.Flags;
				omAreas[i] = con.AreaType;
				omDir[i] = con.Bidirectional ? (uint8)1 : (uint8)0;
				omUserID[i] = con.UserID;
			}

			createParams.offMeshConVerts = omVerts;
			createParams.offMeshConRad = omRad;
			createParams.offMeshConFlags = omFlags;
			createParams.offMeshConAreas = omAreas;
			createParams.offMeshConDir = omDir;
			createParams.offMeshConUserID = omUserID;
			createParams.offMeshConCount = omConCount;
		}

		uint8* navData = null;
		int32 navDataSize = 0;
		if (dtCreateNavMeshData(&createParams, &navData, &navDataSize) == 0)
			return .Err;

		// Step 10: Initialize Detour nav mesh
		mNavMesh = dtAllocNavMesh();
		if (mNavMesh == null)
		{
			dtFree(navData);
			return .Err;
		}

		let status = dtNavMeshInitSingle(mNavMesh, navData, navDataSize, (int32)dtTileFlags.DT_TILE_FREE_DATA);
		if (dtStatusFailed(status) != 0)
		{
			dtFree(navData);
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
			return .Err;
		}

		// Step 11: Create query object
		mNavQuery = dtAllocNavMeshQuery();
		if (mNavQuery == null)
		{
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
			return .Err;
		}

		let queryStatus = dtNavMeshQueryInit(mNavQuery, mNavMesh, mMaxQueryNodes);
		if (dtStatusFailed(queryStatus) != 0)
		{
			dtFreeNavMeshQuery(mNavQuery);
			mNavQuery = null;
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
			return .Err;
		}

		// Create default filter
		mQueryFilter = dtAllocQueryFilter();
		if (mQueryFilter != null)
		{
			dtQueryFilterSetIncludeFlags(mQueryFilter, 0xFFFF);
			dtQueryFilterSetExcludeFlags(mQueryFilter, 0);
		}

		mIsBuilt = true;
		return .Ok;
	}

	// ===== Pathfinding =====

	/// Finds a path between two world positions.
	/// Returns the path as a list of waypoints.
	public Result<void> FindPath(Vector3 start, Vector3 end, List<Vector3> outPath)
	{
		if (!mIsBuilt || mNavQuery == null || mQueryFilter == null)
			return .Err;

		outPath.Clear();

		float[3] startPos = .(start.X, start.Y, start.Z);
		float[3] endPos = .(end.X, end.Y, end.Z);
		float[3] halfExtents = .(2.0f, 4.0f, 2.0f);

		// Find nearest polys
		dtPolyRef startRef = 0, endRef = 0;
		float[3] nearestStart = .(), nearestEnd = .();

		dtNavMeshQueryFindNearestPoly(mNavQuery, &startPos, &halfExtents, mQueryFilter, &startRef, &nearestStart);
		dtNavMeshQueryFindNearestPoly(mNavQuery, &endPos, &halfExtents, mQueryFilter, &endRef, &nearestEnd);

		if (startRef == 0 || endRef == 0)
			return .Err;

		// Find polygon path
		const int MAX_POLYS = 256;
		dtPolyRef[MAX_POLYS] polyPath = .();
		int32 pathCount = 0;

		let findStatus = dtNavMeshQueryFindPath(mNavQuery, startRef, endRef, &nearestStart, &nearestEnd,
			mQueryFilter, &polyPath, &pathCount, MAX_POLYS);

		if (dtStatusFailed(findStatus) != 0 || pathCount == 0)
			return .Err;

		// Find straight path
		const int MAX_STRAIGHT = 256;
		float[MAX_STRAIGHT * 3] straightPath = .();
		uint8[MAX_STRAIGHT] straightPathFlags = .();
		dtPolyRef[MAX_STRAIGHT] straightPathRefs = .();
		int32 straightPathCount = 0;

		dtNavMeshQueryFindStraightPath(mNavQuery, &nearestStart, &nearestEnd,
			&polyPath, pathCount, &straightPath, &straightPathFlags, &straightPathRefs,
			&straightPathCount, MAX_STRAIGHT, 0);

		for (int32 i = 0; i < straightPathCount; i++)
		{
			outPath.Add(Vector3(
				straightPath[i * 3],
				straightPath[i * 3 + 1],
				straightPath[i * 3 + 2]
			));
		}

		return .Ok;
	}

	/// Finds the nearest point on the navigation mesh to the given position.
	public Result<Vector3> FindNearestPoint(Vector3 position)
	{
		if (!mIsBuilt || mNavQuery == null || mQueryFilter == null)
			return .Err;

		float[3] pos = .(position.X, position.Y, position.Z);
		float[3] halfExtents = .(2.0f, 4.0f, 2.0f);

		dtPolyRef nearestRef = 0;
		float[3] nearest = .();

		let status = dtNavMeshQueryFindNearestPoly(mNavQuery, &pos, &halfExtents, mQueryFilter, &nearestRef, &nearest);
		if (dtStatusFailed(status) != 0 || nearestRef == 0)
			return .Err;

		return Vector3(nearest[0], nearest[1], nearest[2]);
	}

	/// Casts a ray along the navigation mesh surface.
	public NavRaycastResult Raycast(Vector3 start, Vector3 end)
	{
		NavRaycastResult result = .();
		result.Fraction = 1.0f;
		result.Position = end;

		if (!mIsBuilt || mNavQuery == null || mQueryFilter == null)
			return result;

		float[3] startPos = .(start.X, start.Y, start.Z);
		float[3] endPos = .(end.X, end.Y, end.Z);
		float[3] halfExtents = .(2.0f, 4.0f, 2.0f);

		// Find start poly
		dtPolyRef startRef = 0;
		float[3] nearestStart = .();
		dtNavMeshQueryFindNearestPoly(mNavQuery, &startPos, &halfExtents, mQueryFilter, &startRef, &nearestStart);

		if (startRef == 0)
			return result;

		float t = 0;
		float[3] hitNormal = .();
		const int MAX_POLYS = 64;
		dtPolyRef[MAX_POLYS] path = .();
		int32 pathCount = 0;

		dtNavMeshQueryRaycast(mNavQuery, startRef, &nearestStart, &endPos, mQueryFilter,
			&t, &hitNormal, &path, &pathCount, MAX_POLYS);

		result.Fraction = t;
		result.HasHit = t < 1.0f;
		result.Normal = Vector3(hitNormal[0], hitNormal[1], hitNormal[2]);

		if (result.HasHit)
		{
			// Interpolate hit position
			result.Position = Vector3.Lerp(start, end, t);
		}

		return result;
	}

	/// Gets a random navigable point.
	public Result<Vector3> GetRandomPoint()
	{
		if (!mIsBuilt || mNavQuery == null || mQueryFilter == null)
			return .Err;

		dtPolyRef randomRef = 0;
		float[3] randomPt = .();

		let status = dtNavMeshQueryFindRandomPoint(mNavQuery, mQueryFilter, => RandomFloat, &randomRef, &randomPt);
		if (dtStatusFailed(status) != 0)
			return .Err;

		return Vector3(randomPt[0], randomPt[1], randomPt[2]);
	}

	/// The underlying Detour nav mesh handle (for CrowdManager).
	public dtNavMeshHandle NavMeshHandle => mNavMesh;

	// ===== Private =====

	private void Cleanup()
	{
		if (mQueryFilter != null)
		{
			dtFreeQueryFilter(mQueryFilter);
			mQueryFilter = null;
		}

		if (mNavQuery != null)
		{
			dtFreeNavMeshQuery(mNavQuery);
			mNavQuery = null;
		}

		if (mNavMesh != null)
		{
			dtFreeNavMesh(mNavMesh);
			mNavMesh = null;
		}

		mIsBuilt = false;
	}

	private static float RandomFloat()
	{
		// Simple LCG random
		mSeed = mSeed * 1103515245 + 12345;
		return (float)(mSeed & 0x7FFFFFFF) / (float)0x7FFFFFFF;
	}

	private static uint32 mSeed = 42;

	protected override void OnRemoved()
	{
		Cleanup();
	}
}
