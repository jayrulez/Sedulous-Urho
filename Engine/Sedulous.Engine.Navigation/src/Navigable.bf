using System;
using Sedulous.Engine.Core;

namespace Sedulous.Engine.Navigation;

/// Marker component that flags a node's geometry for navigation mesh generation.
///
/// When NavigationMesh builds, it collects triangle geometry from nodes that
/// have a Navigable component. If Recursive is true, child node geometry
/// is also included.
///
[EngineComponent("Navigation")]
public class Navigable : Component
{
	private bool mRecursive = true;

	/// Whether child nodes are also included in the nav mesh build.
	[Editable("Recursive")]
	public bool Recursive
	{
		get => mRecursive;
		set => mRecursive = value;
	}
}
