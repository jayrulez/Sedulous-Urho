using System;

namespace Sedulous.Engine.Core;

/// Delegate for frame lifecycle events with no parameters.
public delegate void FrameEventHandler();

/// Delegate for update events that receive the time step.
public delegate void UpdateEventHandler(float timeStep);

/// Delegate for window resize events.
public delegate void ResizeEventHandler(int32 width, int32 height);
