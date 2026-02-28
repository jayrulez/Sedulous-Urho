namespace Sedulous.Resources;

/// The loading state of a resource.
enum ResourceState : uint32
{
	/// Not loaded yet.
	Empty = 0,
	/// Successfully loaded and ready for use.
	Ready,
	/// Loading failed.
	Failure
}
