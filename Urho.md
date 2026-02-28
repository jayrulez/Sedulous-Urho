# Urho-Inspired Engine on Sedulous — Implementation Plan

## Overview

Build an Urho3D-inspired game engine on top of the Sedulous framework, leveraging Beef's native reflection and compile-time code generation. The engine follows Urho's **scene/node/component** architecture while using Sedulous's modern subsystems (Vulkan RHI, Jolt Physics, SDL3, etc.) and a **render graph** instead of Urho's XML render paths.

### Key Architectural Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Object Model | Beef reflection + custom attributes | Idiomatic Beef, compile-time safety, less boilerplate than Urho's macros |
| Event System | Typed events (EventAccessor\<T\>) | Type-safe, compile-time checked, IDE-friendly |
| Rendering | Render graph (Sedulous.RenderGraph) | Modern Vulkan-native approach, auto resource management |
| Networking | Deferred | Build scene graph first; design interfaces for future network replication |

### Sedulous Subsystems Already Available

- **Foundation** — Math, logging, events, collections
- **RHI + RHI.Vulkan** — Modern GPU abstraction (buffers, textures, pipelines, command encoders)
- **Shell + Shell.SDL3** — Windowing, input (keyboard, mouse, gamepad, touch), clipboard, dialogs
- **Jobs** — Thread pool, async job execution, priorities
- **Resources** — Resource system with GUID/path resolution, caching, async loading
- **Serialization** — OpenDDL and XML serializers
- **Models** — GLTF and FBX loaders
- **Imaging** — Image loading (STB, SDL)
- **Textures / Fonts / Geometry** — Asset pipelines
- **Animation** — Full skeletal animation (clips, graphs, blend trees, layers, bone masks)
- **Audio** — 3D spatial audio, streaming, multiple codecs (SDL3 backend)
- **Physics** — Jolt Physics (rigid bodies, shapes, constraints, character controllers, raycasts)
- **Navigation** — Recast/Detour pathfinding
- **GUI** — UI toolkit with shell integration
- **Profiler** — Frame-based performance profiling
- **Net** — Networking base + HTTP
- **Shaders / Materials / Drawing** — Shader management, material definitions, 2D drawing

---

## Phase 0 — Object Model & Engine Core

**Goal:** Establish the Urho-style object model using Beef reflection — the foundation everything else builds on.

**Project:** `Sedulous.Engine.Core`

### 0.1 Custom Attributes for Reflection

Define custom Beef attributes that drive component registration, serialization, and editor integration:

```beef
// Marks a class as a registerable engine component
[AttributeUsage(.Class, .ReflectAttribute, ReflectUser=.Fields | .Methods)]
struct EngineComponentAttribute : Attribute
{
    public String Category;  // e.g. "Rendering", "Physics", "Audio"
    public this(String category = "General") { Category = category; }
}

// Marks a field as a serializable/editable attribute
[AttributeUsage(.Field, .ReflectAttribute)]
struct EditableAttribute : Attribute
{
    public String DisplayName;
    public this(String displayName = null) { DisplayName = displayName; }
}

// Marks a field that should not serialize (transient)
[AttributeUsage(.Field, .ReflectAttribute)]
struct TransientAttribute : Attribute { }

// Marks default value for attribute serialization (only serialize if changed)
[AttributeUsage(.Field, .ReflectAttribute)]
struct DefaultValueAttribute : Attribute
{
    public Variant Value;
    public this(Variant value) { Value = value; }
}
```

Use Beef's `[AlwaysInclude(AssumeInstantiated=true)]` on component classes so `Type.CreateObject()` works at runtime for factory instantiation.

### 0.2 Context (Central Engine Registry)

Urho's `Context` is the glue — subsystem registry, object factory, and attribute store. In Beef, this becomes cleaner:

```
Context
├── SubsystemRegistry — GetSubsystem<T>() / RegisterSubsystem()
├── ComponentFactory — CreateComponent(Type) using Beef reflection
│   └── Auto-discovers [EngineComponent] types at startup via Type.Types
├── EventBus — Typed event dispatching (leveraging EventAccessor<T>)
└── GlobalState — Engine-wide configuration
```

- **SubsystemRegistry**: `Dictionary<Type, Object>` mapping subsystem types to instances. Wraps existing Sedulous subsystems (Shell, Audio, Physics, etc.) as engine subsystems.
- **ComponentFactory**: Scans `Type.Types` at startup for types with `[EngineComponent]`, stores them in a registry. `CreateComponent(typeName)` instantiates via `Type.CreateObject()`.
- **No StringHash needed**: Beef's `Type` and `String` serve as identifiers directly; StringHash can be used as an optimization for hot paths if profiling shows need.

### 0.3 Engine Lifecycle

Port Urho's `Engine` and `Application` pattern:

```
Engine
├── Initialize(EngineParameters) — Create subsystems, open window
├── RunFrame() — One frame: ProcessInput → Update → Render
├── Shutdown() — Cleanup in reverse order

Application : Engine
├── Setup() — Override to configure parameters before init
├── Start() — Override to create initial scene, load resources
├── Stop() — Override to cleanup
└── Run() — Main loop: Initialize → loop RunFrame → Shutdown
```

**Frame events** (typed, via EventAccessor):
- `FrameBeginEvent`
- `UpdateEvent { float TimeStep; }`
- `PostUpdateEvent`
- `RenderUpdateEvent`
- `PostRenderUpdateEvent`
- `FrameEndEvent`

### 0.4 Subsystem Wrappers

Thin adapter interfaces exposing existing Sedulous subsystems through the Context:

| Engine Subsystem | Wraps |
|-----------------|-------|
| `EngineGraphics` | `Sedulous.RHI` (IDevice, IBackend) |
| `EngineInput` | `Sedulous.Shell` (IInputManager) |
| `EngineAudio` | `Sedulous.Engine.Audio` (IAudioSystem) |
| `EnginePhysics` | `Sedulous.Engine.Physics` (IPhysicsWorld) — per-scene |
| `EngineResources` | `Sedulous.Resources` (ResourceSystem) |
| `EngineJobs` | `Sedulous.Jobs` (JobSystem) |

**Deliverables:**
- [ ] Custom attribute definitions (`[EngineComponent]`, `[Editable]`, `[Transient]`, `[DefaultValue]`)
- [ ] `Context` class with subsystem registry and component factory
- [ ] `Engine` class with frame loop and event dispatch
- [ ] `Application` base class with Setup/Start/Stop lifecycle
- [ ] Subsystem wrapper interfaces
- [ ] Minimal working app: opens a window, runs the frame loop, processes input

---

## Phase 1 — Scene Graph

**Goal:** Implement Urho's scene/node/component hierarchy — the core data model for all game objects.

**Project:** `Sedulous.Engine.Core` (scene graph is fundamental to the engine)

### 1.1 Node

```
Node
├── Transform — Position, Rotation (Quaternion), Scale (local space)
│   ├── WorldTransform — Cached, dirty-flag propagation
│   └── SetTransform() — Atomic set with dirty cascade
├── Children — List<Node>, ordered
│   ├── CreateChild(name) → Node
│   ├── RemoveChild(node)
│   └── GetChild(name, recursive)
├── Components — List<Component>
│   ├── CreateComponent<T>() → T
│   ├── GetComponent<T>() → T?
│   ├── GetComponents<T>(list)
│   └── RemoveComponent(component)
├── Parent — weak reference
├── Scene — reference to owning scene
├── Name / Tags — identification
├── Enabled — cascading enable/disable
└── ID — unique within scene
```

Key behaviors from Urho:
- **Dirty flag transform propagation**: When a node's transform changes, mark it and all descendants dirty. Recalculate world transform lazily on access.
- **Cascading enable/disable**: Disabling a node disables all its components and children.
- **Tag system**: Multiple string tags per node for grouping/querying.

### 1.2 Component

```
Component
├── Node — owning node (set on attach)
├── Scene — owning scene
├── Enabled — can be independently disabled
├── ID — unique within scene
├── Virtual Lifecycle:
│   ├── OnNodeSet(node) — called when attached to a node
│   ├── OnSceneSet(scene) — called when node enters a scene
│   ├── OnEnabled() / OnDisabled()
│   ├── OnTransformChanged() — node transform was modified
│   └── OnRemoved() — about to be detached
```

All game functionality (rendering, physics, audio, etc.) is implemented as components. The `[EngineComponent]` attribute + Beef reflection handles registration.

### 1.3 Scene

```
Scene : Node
├── NodeRegistry — Dictionary<uint32, Node> for ID-based lookup
├── ComponentRegistry — Dictionary<uint32, Component> for ID-based lookup
├── TagIndex — Dictionary<String, List<Node>> for tag-based queries
├── TimeScale — slow motion / pause
├── ElapsedTime
├── UpdateEnabled — can pause scene updates
├── Load/Save — full scene serialization (Phase 6)
├── Instantiate(prefab) — instantiate a node hierarchy (Phase 6)
└── GetNodesWithTag(tag) → List<Node>
```

### 1.4 Scene Update Pipeline

Each frame, the engine dispatches typed events that components subscribe to:

1. `SceneUpdateEvent { Scene, float TimeStep }` — logic update
2. `ScenePostUpdateEvent` — post-logic cleanup
3. Components that need per-frame updates implement `IUpdatable` interface or subscribe to the scene's update event.

**Deliverables:**
- [ ] `Node` class with transform hierarchy, children, components, tags
- [ ] `Component` base class with lifecycle hooks
- [ ] `Scene` class with registries and update pipeline
- [ ] ID generation (sequential, local scope — network IDs deferred)
- [ ] Unit tests for transform propagation, component lifecycle, node hierarchy

---

## Phase 2 — Render Graph

**Goal:** Build the render graph infrastructure that replaces Urho's XML render paths. This is the scheduling backbone for all rendering.

**Project:** `Sedulous.RenderGraph` (new project)

### 2.1 Render Graph Core

A render graph describes the frame's rendering work as a DAG of passes with declared resource dependencies. The graph compiler figures out resource lifetimes, barriers, and execution order.

```
RenderGraph
├── AddPass<T>(name, setup, execute) — Declare a render/compute pass
├── ImportTexture(ITexture) — Import external resource (e.g. swapchain)
├── ImportBuffer(IBuffer) — Import external buffer
├── CreateTexture(desc) — Declare a transient texture
├── CreateBuffer(desc) — Declare a transient buffer
├── Compile() — Resolve dependencies, cull unused passes, allocate resources
├── Execute(ICommandEncoder) — Execute passes in dependency order
└── Reset() — Clear for next frame

RenderGraphPass
├── Read(handle) — Declare read dependency
├── Write(handle) — Declare write dependency
├── SetRenderTarget(handle) — Declare color attachment
├── SetDepthStencil(handle) — Declare depth attachment
└── ExecuteCallback — User function that records GPU commands

ResourceHandle
├── ID — graph-local identifier
├── Version — tracks read-after-write dependencies
└── Description — texture/buffer descriptor for transient allocation
```

### 2.2 Resource Management

- **Transient resources**: Created and destroyed within a frame. The graph compiler pools and aliases memory.
- **Imported resources**: Externally managed (swapchain, persistent render targets). The graph tracks their state but doesn't manage lifetime.
- **Automatic barriers**: The compiler inserts layout transitions and memory barriers based on read/write declarations.

### 2.3 Pass Types

- **Raster Pass**: Renders to color/depth attachments via `IRenderPassEncoder`
- **Compute Pass**: Dispatches compute work via `IComputePassEncoder`
- **Transfer Pass**: Copies, blits, readbacks

### 2.4 Built-in Passes (Scaffolding)

Provide a few built-in pass templates:

- `ClearPass` — Clears render targets
- `FullscreenPass` — Renders a fullscreen triangle with a shader (post-processing)
- `BlitPass` — Copies one texture to another

**Deliverables:**
- [ ] `RenderGraph` class with pass declaration, compilation, execution
- [ ] `RenderGraphPass` with resource dependency tracking
- [ ] `ResourceHandle` for transient and imported resources
- [ ] Automatic resource barrier insertion for Vulkan
- [ ] Transient resource pooling/aliasing
- [ ] Built-in pass templates (Clear, Fullscreen, Blit)
- [ ] Integration test: render a colored clear to swapchain via render graph

---

## Phase 3 — Core Renderer

**Goal:** Implement the high-level renderer that bridges the scene graph and the render graph, getting 3D geometry on screen.

**Project:** `Sedulous.Engine.Renderer`

### 3.1 Drawable (Base Renderable Component)

Port Urho's `Drawable` concept — the base class for anything visible:

```
Drawable : Component
├── BoundingBox (local space)
├── WorldBoundingBox (cached)
├── DrawDistance / ShadowDistance / LodBias
├── ViewMask / LightMask / ShadowMask / ZoneMask
├── CastShadows
├── GetBatches(FrameInfo) → List<SourceBatch>
│   └── SourceBatch { Geometry, Material, WorldTransform, Distance }
├── Octree insertion/removal on transform change
└── UpdateBatches() — per-frame LOD/distance update
```

### 3.2 Octree (Spatial Indexing)

```
Octree : Component (attached to Scene root)
├── Insert(drawable) / Remove(drawable) / Update(drawable)
├── QueryFrustum(frustum) → List<Drawable> — visibility culling
├── QuerySphere(sphere) → List<Drawable> — proximity queries
├── QueryBox(box) → List<Drawable> — region queries
├── Raycast(ray) → List<RaycastResult> — picking
└── Configurable: world bounds, max depth, min node size
```

Drawables register themselves with the Octree when added to a scene. The octree re-inserts drawables when their bounds change (dirty flag from transform change).

### 3.3 Camera Component

```
Camera : Component
├── ProjectionMode — Perspective / Orthographic
├── FOV, NearClip, FarClip, AspectRatio
├── ViewMatrix (from node world transform)
├── ProjectionMatrix
├── Frustum (for culling)
├── ViewMask (filter drawables)
└── GetScreenRay(x, y) → Ray — for picking
```

### 3.4 Light Component

```
Light : Drawable
├── LightType — Directional / Point / Spot
├── Color, Brightness, Temperature
├── Range (point/spot), SpotAngle, SpotInnerAngle
├── CastShadows, ShadowBias, ShadowResolution
├── ShadowCascades (directional only)
├── LightMask — which drawables this light affects
└── Generates shadow camera frustums for shadow mapping
```

### 3.5 Zone Component

```
Zone : Component
├── AmbientColor
├── FogColor, FogStart, FogEnd
├── ZoneMask — which drawables belong to this zone
├── Priority — for overlapping zones
└── BoundingBox — zone volume
```

### 3.6 StaticModel Component

```
StaticModel : Drawable
├── Model resource (from Sedulous.Geometry.StaticMesh)
├── Materials (per geometry/LOD slot)
├── LOD distances
├── Occlusion — can be occluder
└── GetBatches() — returns geometry batches with materials
```

### 3.7 Renderer Subsystem

The high-level `Renderer` orchestrates per-frame rendering:

```
Renderer : Subsystem
├── Viewports — List<Viewport> (scene + camera + render target)
├── SetViewport(index, viewport)
├── Update(timeStep):
│   For each Viewport:
│   1. Cull: Query octree with camera frustum → visible drawables
│   2. Collect: Gather SourceBatches from drawables
│   3. Light assignment: Determine which lights affect each drawable
│   4. Sort: Front-to-back (opaque), back-to-front (transparent)
│   5. Shadow: Determine shadow casters per shadow-casting light
├── Render():
│   Build render graph for current frame:
│   1. Shadow map passes (per light)
│   2. GBuffer / Forward opaque pass
│   3. Light pass (deferred) or per-batch lighting (forward)
│   4. Transparent pass
│   5. Post-processing passes
│   6. UI pass
│   Execute render graph
└── DefaultMaterials, DefaultZone — fallback state
```

### 3.8 Viewport

```
Viewport
├── Scene
├── Camera
├── RenderTarget (null = backbuffer)
├── Rectangle (sub-region of target)
└── RenderPath overrides (optional)
```

**Deliverables:**
- [ ] `Drawable` base component with bounding volumes and batch generation
- [ ] `Octree` component with frustum/sphere/box/ray queries
- [ ] `Camera` component with projection and frustum
- [ ] `Light` component (directional, point, spot)
- [ ] `Zone` component (ambient, fog)
- [ ] `StaticModel` component rendering static meshes
- [ ] `Renderer` subsystem with per-frame cull → sort → render graph build → execute
- [ ] `Viewport` linking scene, camera, and render target
- [ ] Working demo: Load a GLTF model, place camera, render with a directional light

---

## Phase 4 — Materials & Shaders

**Goal:** Implement the material system that controls how geometry is rendered.

**Projects:** `Sedulous.Materials` (enhance existing), `Sedulous.Shaders` (enhance existing)

### 4.1 Material System

Adapt Urho's Material/Technique/Pass model for the render graph:

```
Material : Resource
├── Techniques — List<TechniqueEntry> (technique + quality + LOD distance)
├── ShaderParameters — Dictionary<String, Variant> (uniforms)
├── Textures — Dictionary<TextureUnit, TextureResource> (diffuse, normal, specular, etc.)
├── RenderOrder — sorting priority for transparency
├── CullMode, FillMode
├── DepthWrite, DepthTest
├── BlendMode
└── GetBestTechnique(quality, distance) → Technique
```

### 4.2 Technique & Pass

```
Technique : Resource
├── Passes — Dictionary<String, Pass>  (e.g. "base", "light", "shadow", "depth")
└── IsSupported(graphics) — check feature requirements

Pass
├── VertexShader / PixelShader — shader resource references
├── ShaderDefines — compile-time variations (e.g. "NORMALMAP", "SKINNED")
├── BlendMode, CullMode, DepthWrite, DepthTest
├── ColorWrite
└── Compiled pipeline state (cached per pass + vertex format combination)
```

### 4.3 Shader System

```
ShaderProgram : Resource
├── Source — HLSL/GLSL source or SPIR-V bytecode
├── GetVariation(defines) → ShaderVariation (cached compilation)
└── Reflection — uniform locations, texture bindings

ShaderVariation
├── CompiledModule — IShaderModule (from RHI)
├── Defines — set of active defines
├── UniformBindings — layout information
└── Key — hash of (source + defines) for caching
```

Use Sedulous.Shaders + Dxc-Beef for HLSL→SPIR-V compilation. Cache compiled variations.

### 4.4 Pipeline State Caching

Pipeline states (IRenderPipeline) are expensive to create in Vulkan. Cache them keyed by:
- Pass (shaders + render state)
- Vertex format (from geometry)
- Render target format (from render graph pass)

```
PipelineStateCache
├── GetOrCreate(pass, vertexFormat, renderTargetFormat) → IRenderPipeline
└── Invalidate() — on device lost or shader reload
```

**Deliverables:**
- [ ] `Material` resource with techniques, shader parameters, textures
- [ ] `Technique` resource with named passes
- [ ] `Pass` with shader references and render state
- [ ] Shader compilation and variation caching
- [ ] Pipeline state cache
- [ ] Material loading from file (serialization format TBD — XML or OpenDDL)
- [ ] Default materials: unlit color, basic lit, PBR metallic-roughness

---

## Phase 5 — Advanced Rendering

**Goal:** Implement shadow mapping, instancing, skinned rendering, and post-processing.

**Project:** `Sedulous.Engine.Renderer`

### 5.1 Shadow Mapping

- **Directional lights**: Cascaded Shadow Maps (CSM) with 2–4 splits
- **Spot lights**: Single shadow map with perspective projection
- **Point lights**: Cube shadow map or dual-paraboloid
- Shadow passes added to render graph automatically for shadow-casting lights
- Shadow atlas for efficient texture memory usage
- Configurable bias (depth, slope, normal offset)

### 5.2 AnimatedModel Component

```
AnimatedModel : StaticModel
├── Skeleton — bone hierarchy from model
├── AnimationStates — active animation playback instances
├── BoneNodes — Node references for each bone (for attachments)
├── Morphs — vertex morph targets (blend shapes)
├── PlayAnimation(clip, layer, weight) → AnimationState
├── UpdateSkeleton() — evaluate animations, update bone matrices
└── GetBatches() — includes bone matrix uniform data
```

Integrates with Sedulous.Engine.Animation (AnimationPlayer, AnimationGraph, BlendTree).

### 5.3 GPU Instancing

- Drawables with the same geometry + material are batched into instanced draw calls
- Instance buffer carries per-instance data (world transform, custom data)
- Minimum instance count threshold before instancing kicks in
- Render graph pass collects instance groups during batch sorting

### 5.4 Post-Processing

Built on render graph fullscreen passes:
- **Tone mapping** (HDR → LDR)
- **Bloom** (bright pass + blur + composite)
- **FXAA / TAA** (anti-aliasing)
- **SSAO** (screen-space ambient occlusion)
- **Depth of Field**
- Post-processing stack configurable per viewport

### 5.5 Additional Drawable Components

- `BillboardSet` — Camera-facing quads (particles, sprites)
- `ParticleEmitter` — Particle system component using `ParticleEffect` resource
- `Skybox` — Cubemap-based skybox rendering
- `Terrain` — Heightmap terrain with LOD
- `DecalSet` — Projected decals on geometry
- `DebugRenderer` — Wireframe debug visualization (lines, shapes, text)

**Deliverables:**
- [ ] Shadow mapping (CSM for directional, single for spot, cube for point)
- [ ] Shadow atlas management
- [ ] `AnimatedModel` component with skeleton integration
- [ ] GPU instancing for static geometry
- [ ] Post-processing stack (tone mapping, bloom, FXAA at minimum)
- [ ] `BillboardSet`, `ParticleEmitter`, `Skybox` components
- [ ] `DebugRenderer` for development visualization

---

## Phase 6 — Scene Serialization & Prefabs

**Goal:** Save/load scenes and instantiate prefab node hierarchies — critical for editor workflow.

**Projects:** `Sedulous.Engine.Core`

### 6.1 Attribute Serialization via Reflection

Use the `[Editable]` and `[DefaultValue]` attributes to drive automatic serialization:

```beef
[EngineComponent("Rendering")]
class StaticModel : Drawable
{
    [Editable("Model"), ResourceRef]
    ResourceHandle<StaticMeshResource> mModel;

    [Editable("Cast Shadows"), DefaultValue(true)]
    bool mCastShadows = true;

    [Editable("LOD Bias"), DefaultValue(1.0f)]
    float mLodBias = 1.0f;
}
```

At save time, iterate fields with `[Editable]` via reflection, skip those matching `[DefaultValue]`. At load time, set fields via reflection. This replaces Urho's manual `URHO3D_ATTRIBUTE` macros entirely.

Use a compile-time `[Comptime]` function to generate optimized serialization code per component type (avoiding runtime reflection overhead in hot paths).

### 6.2 Scene Serialization

```
SceneSerializer
├── SaveScene(scene, stream, format) — Serialize entire scene hierarchy
├── LoadScene(scene, stream, format) — Deserialize into existing scene
├── SaveNode(node, stream, format) — Save a subtree (prefab)
├── LoadNode(scene, stream, format) → Node — Instantiate a prefab
└── Formats: XML (human-readable), Binary (compact), OpenDDL
```

Serialization order (matches Urho):
1. Scene attributes
2. For each node (depth-first):
   a. Node attributes (name, transform, tags, enabled)
   b. Number of components
   c. For each component: type name + attributes
   d. Number of children
   e. Recurse into children

### 6.3 Prefab System

- A **prefab** is a serialized node subtree (a file)
- `Scene.Instantiate(prefab, position, rotation)` loads and attaches
- Prefabs can be nested (a prefab references other prefabs)
- Resource handle for prefab files — loaded via ResourceSystem

**Deliverables:**
- [ ] Reflection-based attribute serializer (reads `[Editable]` fields)
- [ ] Optional compile-time codegen for fast serialization paths
- [ ] `SceneSerializer` with XML and binary formats
- [ ] Prefab save/load/instantiate
- [ ] Unit tests for round-trip serialization of all component types

---

## Phase 7 — Physics, Audio & Navigation as Scene Components

**Goal:** Wrap existing Sedulous subsystems as scene components following Urho's patterns.

**Projects:** `Sedulous.Engine.Physics`, `Sedulous.Engine.Audio`, `Sedulous.Engine.Navigation`

### 7.1 Physics Components

Wrap Jolt Physics as Urho-style components:

```
PhysicsWorld : Component (one per scene, attached to root)
├── Gravity, TimeStep, MaxSubSteps
├── Raycast(ray, maxDist, mask) → RaycastResult
├── ShapeCast(shape, from, to) → ShapeCastResult
├── DebugDraw(DebugRenderer)
└── Steps simulation during SceneUpdate

RigidBody : Component
├── Mass (0 = static)
├── BodyType — Static / Kinematic / Dynamic
├── LinearVelocity, AngularVelocity
├── Friction, Restitution, Damping
├── CollisionLayer, CollisionMask
├── CCD enabled
├── Trigger mode
├── ApplyForce/Impulse/Torque
└── Syncs Node transform ↔ Physics body transform

CollisionShape : Component
├── ShapeType — Box / Sphere / Capsule / Cylinder / ConvexHull / TriangleMesh
├── Size / Radius / Height
├── Offset position/rotation
└── Shared shape data caching

Constraint : Component
├── ConstraintType — Fixed / Point / Hinge / Slider / Distance
├── OtherBody — connected RigidBody
├── Axis, Limits, Motor settings
└── Break force/torque thresholds

CharacterController : Component
├── Height, Radius, StepHeight
├── Move(velocity), Jump()
├── IsGrounded, GroundNormal
└── Integrates with Jolt character controller
```

### 7.2 Audio Components

Wrap SDL3 audio as scene components:

```
SoundSource : Component (2D audio)
├── Sound resource (AudioClipResource)
├── Volume, Pitch, Panning
├── Play() / Stop() / Pause()
├── Looping
├── AutoRemove — remove component/node when done
└── Wraps IAudioSource

SoundSource3D : SoundSource
├── NearDistance, FarDistance
├── RolloffFactor
├── InnerAngle, OuterAngle (directional cone)
└── Uses node world position for 3D spatialization

SoundListener : Component
├── Marks this node as the active audio listener
└── Uses node world position/orientation
```

### 7.3 Navigation Components

Wrap Recast/Detour as scene components:

```
NavigationMesh : Component (one per scene)
├── CellSize, CellHeight, AgentHeight, AgentRadius
├── Build(boundingBox) — generate nav mesh from scene geometry
├── FindPath(from, to) → List<Vector3>
├── Raycast(from, to) → NavRaycastResult
├── GetRandomPoint() → Vector3
└── DebugDraw(DebugRenderer)

CrowdManager : Component
├── MaxAgents, ObstacleAvoidance settings
└── Manages group pathfinding

CrowdAgent : Component
├── TargetPosition, MaxSpeed, MaxAcceleration
├── NavigationQuality, AvoidancePriority
└── Updates node position from pathfinding result

Navigable : Component
├── Marks node's geometry for nav mesh generation
└── Recursive flag for children

Obstacle : Component
├── Radius, Height
└── Dynamic obstacle for crowd avoidance

OffMeshConnection : Component
├── Endpoint node
├── Radius, Bidirectional
└── Manual navigation links
```

**Deliverables:**
- [ ] `PhysicsWorld`, `RigidBody`, `CollisionShape`, `Constraint`, `CharacterController` components
- [ ] Physics ↔ Node transform synchronization
- [ ] Collision events as typed events
- [ ] `SoundSource`, `SoundSource3D`, `SoundListener` components
- [ ] `NavigationMesh`, `CrowdManager`, `CrowdAgent`, `Navigable`, `Obstacle`, `OffMeshConnection`
- [ ] Navigation mesh building from scene geometry
- [ ] Debug visualization for physics shapes, nav mesh, audio sources

---

## Phase 8 — Editor

**Goal:** Build a functional scene editor for creating and editing game content.

**Projects:** `Sedulous.Editor.Core`, `Sedulous.Editor.App`, and `Sedulous.Editor.*` modules

### 8.1 Editor Architecture

```
Editor : Application
├── EditorScene — the scene being edited
├── EditorViewport — 3D viewport with camera controls
├── Gizmos — translate/rotate/scale manipulation
├── Selection — selected nodes/components
├── Inspector — shows [Editable] fields for selected objects
│   └── Auto-generated from Beef reflection on component fields
├── SceneHierarchy — tree view of nodes
├── ResourceBrowser — asset library
├── UndoRedo — command pattern for all edits
├── Play/Stop — enter/exit play mode (serializes scene, restores on stop)
└── Prefab editing — edit prefab files in isolation
```

### 8.2 Inspector Auto-Generation

The inspector reads `[Editable]` fields via reflection and generates appropriate UI widgets:
- `bool` → Checkbox
- `float/int` → Slider or number input (with `[Range]` attribute)
- `String` → Text input
- `Vector3` → XYZ inputs
- `Quaternion` → Euler angle inputs
- `Color` → Color picker
- `ResourceRef` → Asset picker with drag-and-drop
- `enum` → Dropdown

### 8.3 Undo/Redo System

Every editor operation is a `Command`:
```
ICommand
├── Execute()
├── Undo()
├── Description — for display

CommandHistory
├── Execute(command) — execute and push
├── Undo() / Redo()
└── CanUndo / CanRedo
```

Commands: SetAttribute, CreateNode, DeleteNode, CreateComponent, DeleteComponent, ReparentNode, MoveNode, etc.

### 8.4 Editor-Specific Modules

| Module | Responsibility |
|--------|---------------|
| `Editor.Renderer` | Viewport rendering, gizmo rendering, selection highlighting, grid |
| `Editor.Physics` | Physics shape visualization, physics simulation toggle |
| `Editor.Animation` | Animation preview, timeline, blend tree editor |
| `Editor.Navigation` | Nav mesh visualization, build controls |
| `Editor.Audio` | Audio source visualization, preview playback |
| `Editor.GUI` | UI layout editor |

**Deliverables:**
- [ ] Editor application with viewport, hierarchy, inspector, resource browser
- [ ] 3D gizmos for translate/rotate/scale
- [ ] Reflection-based inspector auto-generation
- [ ] Undo/redo command system
- [ ] Scene save/load from editor
- [ ] Prefab creation and editing
- [ ] Play/stop mode
- [ ] Editor-specific rendering (grid, gizmos, selection highlight, debug overlays)

---

## Phase 9 — Polish & Advanced Features

**Goal:** Round out the engine with quality-of-life features and advanced capabilities.

### 9.1 Performance

- [x] Frustum culling optimizations (SIMD, multi-threaded octree queries)
- [x] Render batching profiler and optimization
- [x] Async resource loading with progress tracking
- [x] Memory budget management per resource type
- [x] LOD system for models and terrain

### 9.2 Additional Features

- [x] `Terrain` component — heightmap-based terrain with chunked LOD
- [x] `DecalSet` component — projected decals
- [x] `ParticleEffect` resource — data-driven particle definitions
- [x] Lightmap baking support
- [x] Reflection probes
- [x] PBR material pipeline (metallic-roughness workflow)
- [x] Environment mapping (IBL — Image Based Lighting)
- [x] Asset hot-reloading (detect file changes, reload resources)
- [x] Console / debug overlay

### 9.3 Networking (When Ready)

When networking is needed, extend the scene graph:
- Add `NetworkId` to Node and Component (replicated vs local)
- Add `[Networked]` attribute to mark fields for replication
- Delta serialization using `[DefaultValue]` to skip unchanged fields
- Network event system layered on top of typed events
- Client-server scene synchronization via `Sedulous.Net`

### 9.4 Scripting (Optional)

If scripting is desired:
- Beef's compile-time reflection could generate binding code
- Consider Wren, Lua, or a custom DSL
- Component-like scripting: `ScriptComponent` that delegates lifecycle hooks to script functions

---

## Dependency Graph (Build Order)

```
Phase 0: Engine Core (Object Model, Context, Engine, Application)
    │
    ├─── Phase 1: Scene Graph (Node, Component, Scene)
    │        │
    │        ├─── Phase 2: Render Graph (Sedulous.RenderGraph)
    │        │        │
    │        │        └─── Phase 3: Core Renderer (Drawable, Octree, Camera, Light, StaticModel, Renderer)
    │        │                 │
    │        │                 ├─── Phase 4: Materials & Shaders
    │        │                 │        │
    │        │                 │        └─── Phase 5: Advanced Rendering (Shadows, AnimatedModel, Instancing, Post-FX)
    │        │                 │
    │        │                 └─── Phase 8: Editor (needs renderer for viewport)
    │        │
    │        ├─── Phase 6: Scene Serialization & Prefabs
    │        │
    │        └─── Phase 7: Physics, Audio, Navigation Components
    │
    └─── Phase 9: Polish & Advanced (ongoing)
```

**Phases 2, 6, and 7 can proceed in parallel** once Phase 1 is complete.
**Phase 8 (Editor) can start** once Phase 3 has basic rendering working, and grows incrementally with later phases.

---

## Project Structure

```
Sedulous/
├── Sedulous.Engine.Core/         # Phase 0+1: Object model, scene graph
├── Sedulous.Engine.Renderer/     # Phase 3+5: High-level renderer
├── Sedulous.Engine.Physics/      # Phase 7: Physics components (enhance existing)
├── Sedulous.Engine.Audio/        # Phase 7: Audio components (enhance existing)
├── Sedulous.Engine.Navigation/   # Phase 7: Navigation components (enhance existing)
├── Sedulous.Engine.Animation/    # Phase 5: Animation components (enhance existing)
├── Sedulous.Engine.App/          # Phase 0: Application entry point
├── Sedulous.RenderGraph/         # Phase 2: NEW — Render graph infrastructure
├── Sedulous.Editor.Core/         # Phase 8: Editor framework
├── Sedulous.Editor.Renderer/     # Phase 8: Editor viewport/gizmos
├── Sedulous.Editor.App/          # Phase 8: Editor entry point
├── ... (existing libraries remain unchanged)
```

---

## Mapping: Urho3D → Sedulous Engine

| Urho3D Concept | Sedulous Engine Equivalent |
|---|---|
| `URHO3D_OBJECT` macro | `[EngineComponent]` + Beef reflection |
| `Context` | `Context` (subsystem registry + component factory) |
| `StringHash` event bus | Typed events via `EventAccessor<T>` |
| `Variant` / `VariantMap` | Beef `Variant` / typed event structs |
| `Serializable` attributes | `[Editable]` + `[DefaultValue]` + reflection |
| `ResourceCache` | `Sedulous.Resources.ResourceSystem` |
| `Engine` / `Application` | `Engine` / `Application` |
| `Scene` / `Node` / `Component` | `Scene` / `Node` / `Component` |
| XML RenderPath | `Sedulous.RenderGraph` |
| `Renderer` / `View` / `Viewport` | `Renderer` / render graph passes / `Viewport` |
| `Octree` | `Octree` |
| `Drawable` / `StaticModel` / `AnimatedModel` | `Drawable` / `StaticModel` / `AnimatedModel` |
| `Camera` / `Light` / `Zone` | `Camera` / `Light` / `Zone` |
| `Material` / `Technique` / `Pass` | `Material` / `Technique` / `Pass` |
| `PhysicsWorld` (Bullet) | `PhysicsWorld` (Jolt) |
| `RigidBody` / `CollisionShape` | `RigidBody` / `CollisionShape` |
| `Audio` / `SoundSource3D` | `SoundSource` / `SoundSource3D` (SDL3) |
| `NavigationMesh` / `CrowdManager` | `NavigationMesh` / `CrowdManager` (Recast) |
| `UI` widget system | `Sedulous.GUI` |
| `Network` / `Connection` | Deferred (future: `Sedulous.Net` extension) |
| AngelScript / Lua scripting | Deferred (optional) |

---

## Demo: 04_StaticScene Port

**Status:** Running — ground plane + 200 random colored cubes/spheres/cylinders + directional light + WASD/mouse FPS camera.

**File:** `Sedulous.Engine.App/src/Program.bf`

### Bugs Found & Fixed During Bringup

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| Zero draw calls (nothing rendered) | `FrustumCuller` used `BoundingFrustum` planes directly, but BoundingFrustum stores **outward-pointing** normals while the p-vertex culling test requires **inward-pointing** normals. Every object was culled. | Negate all 6 planes and their PosX/PosY/PosZ flags in `FrustumCuller` constructor. (`FrustumCuller.bf:42-48`) |
| Missing dynamic viewport/scissor | Render graph `ExecuteRasterPass` doesn't set viewport/scissor, and the Renderer's pass callbacks didn't either. Vulkan pipelines with dynamic state require explicit calls. | Added `encoder.SetViewport()` and `encoder.SetScissorRect()` at the start of OpaquePass and TransparentPass callbacks. (`Renderer.bf`) |
| Render pass format mismatch (SRGB vs UNORM) | `PipelineConfig` defaults `ColorFormat` to `.BGRA8Unorm` but the Vulkan swapchain uses `.BGRA8UnormSrgb`. | Added `mCurrentColorFormat` field to Renderer, set from `swapChain.Format` each frame, override in `DrawBatch` and `DrawOpaqueBatchesInstanced`. (`Renderer.bf`) |
| Descriptor set 1 not bound | `DrawBatch` didn't bind the per-frame bind group at slot 1, relying on pass-level binding that could be invalidated by pipeline changes. | Added explicit `encoder.SetBindGroup(1, mFrameBindGroup)` in `DrawBatch`. (`Renderer.bf:881`) |
| Shadow atlas UNDEFINED layout | Shadow atlas was imported into render graph only when cascades > 0, and the opaque pass never declared a `Read` dependency on it. The frame bind group always referenced the atlas for sampling, but no barrier was inserted. | Always import shadow atlas; opaque pass declares `builder.Read(shadowAtlas)` so the render graph inserts the depth→shader-read barrier. (`Renderer.bf`) |
| Flipped view | Vulkan NDC Y-axis points downward. Camera had a `FlipY` property (negates `M22`) but the Renderer never enabled it. | Renderer now sets `camera.FlipY = mDevice.FlipProjectionRequired` before frustum computation each frame. (`Renderer.bf`) |
| All objects rendered white | `Color.R/G/B` returns `uint8` (0-255). `UploadFrameUniforms` passed raw uint8 values to float uniforms without dividing by 255. Ambient `(0.2, 0.2, 0.2)` became `(51, 51, 51)` on the GPU, saturating everything to white. | Normalize all Color→float conversions: `(float)color.R / 255.0f` for AmbientColor, FogColor, and Light ColorAndIntensity. (`Renderer.bf:1405,1408,1423`) |
| Crash on shutdown (use-after-free) | In Beef, Node field destructors run in reverse declaration order: `mComponents` (containing Octree) destroyed before `mChildren` (containing Drawables). Drawables' `OnRemoved()` called `mOctree.Remove(this)` on the deleted Octree. | Added `Octree.OnRemoved()` that nulls out all drawables' `OctreeRef` before the Octree is destroyed. (`Octree.bf`) |
| `BoundingFrustum.Contains(Vector3)` bug | Line 66: `plane.Normal.Z + point.Z` uses addition instead of multiplication. Not affecting rendering since `FrustumCuller` does its own math. | Known issue — not yet fixed (only affects `BoundingFrustum.Contains`, not the main culling path). |



=====================================================================================================

Fully Covered (architectural parity or better)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - Scene graph (Node/Component/Scene + serialization)
  - All major drawable types (StaticModel, AnimatedModel, BillboardSet, ParticleEmitter, Skybox, Terrain, DecalSet, RibbonTrail, Sprite2D, ProceduralGeometry)                                                                                                                   - Lighting (directional/point/spot, shadows, zones/fog)                                                                                                                                                                                                                        - PBR materials + shader system
  - Octree + frustum culling                                                                                                                                                                                                                                                     - Post-processing (tone mapping, bloom framework)                                                                                                                                                                                                                              - IBL (reflection probes, environment maps, lightmaps)
  - GPU instancing
  - Physics (Jolt: rigid bodies, shapes, raycasts, character controller API)
  - Navigation (navmesh, crowd, agents, obstacles, off-mesh connections)
  - Audio (3D positional, streaming, WAV/Vorbis/MP3/FLAC)
  - Animation (skeletal, blend trees, state machines, layers, property animation)
  - Resource system (async loading, hot-reload, GLTF/FBX models)
  - Input (keyboard, mouse, touch, gamepad)
  - Debug tools (debug renderer, profiler, debug HUD, memory budget)
  - Editor (native, with undo/redo, hierarchy, inspector)

  Intentional Architectural Differences (modernizations, not gaps)

  - RenderGraph instead of XML RenderPaths
  - Typed events instead of StringHash+VariantMap
  - Beef generics instead of Variant system
  - PipelineConfig instead of Technique/Pass multi-pass system
  - AnimationGraph instead of AnimationController

  Genuine Gaps Worth Noting

  Would matter for some projects:
  - Deferred rendering — limits efficient dynamic light count
  - Convex hull / triangle mesh collision shapes — physics limited to primitives
  - Constraint component — API exists but no scene graph wrapper
  - IK system — no FABRIK/two-bone for foot placement, reaching
  - LogicComponent — no per-frame update base class (must subscribe to events manually)
  - DynamicNavigationMesh — no tile-cache incremental updates
  - ValueAnimation — can't animate arbitrary attributes by name at runtime

  Nice to have but not critical:
  - Software occlusion culling
  - Light cookies/masks
  - Auto-exposure / FXAA post-processes
  - StaticModelGroup (CPU-side batching)
  - PackageFile (.pak archives)
  - JSON parser
  - Localization system
  - In-engine console

  Overall, the core engine feature set is very solid. The gaps are mostly in advanced/niche areas. The biggest real-world ones would be convex hull collision shapes, constraint components, and IK if you're doing character-heavy games.