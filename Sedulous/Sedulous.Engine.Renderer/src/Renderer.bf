using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.Foundation.Logging.Abstractions;
using Sedulous.Engine.Core;
using Sedulous.RHI;
using Sedulous.RenderGraph;
using Sedulous.Shaders;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

using internal Sedulous.Engine.Renderer;

/// High-level renderer subsystem that bridges the scene graph and the render graph.
///
/// The Renderer orchestrates per-frame rendering:
///   1. Update octrees (process pending drawable reinsertions)
///   2. For each viewport: cull, collect batches, assign lights, sort
///   3. Build the render graph (opaque pass, transparent pass, etc.)
///   4. Compile and execute the render graph
///
/// Register this as a subsystem in the Context and hook it into the Engine's
/// RenderUpdate event to drive rendering each frame.
///
public class Renderer
{
	// Viewports (scene + camera + render target)
	private List<Viewport> mViewports = new .() ~ delete _;

	// GPU device
	private IDevice mDevice;

	// Render graph infrastructure (owned)
	private TransientResourcePool mResourcePool ~ { if (_ != null) delete _; };
	private RenderGraph mRenderGraph ~ { if (_ != null) delete _; };

	// Per-frame scratch lists (reused each frame to avoid allocations)
	private List<Drawable> mVisibleGeometry = new .() ~ delete _;
	private List<Drawable> mVisibleLights = new .() ~ delete _;
	private List<Drawable> mVisibleZones = new .() ~ delete _;
	private List<SourceBatch> mOpaqueBatches = new .() ~ delete _;
	private List<SourceBatch> mTransparentBatches = new .() ~ delete _;
	private List<Light> mLightList = new .() ~ delete _;

	// Default zone fallback
	private Zone mDefaultZone ~ { if (_ != null) delete _; };

	// Material & shader subsystems (owned)
	private ShaderSystem mShaderSystem ~ { if (_ != null) delete _; };
	private MaterialSystem mMaterialSystem ~ { if (_ != null) delete _; };
	private PipelineStateCache mPipelineCache ~ { if (_ != null) delete _; };

	// Per-frame uniform buffer (view/projection/camera/lights/fog) — slot 1
	private IBuffer mFrameUniformBuffer ~ { if (_ != null) delete _; };
	private IBindGroupLayout mFrameBindGroupLayout ~ { if (_ != null) delete _; };
	private IBindGroup mFrameBindGroup ~ { if (_ != null) delete _; };

	// Per-object dynamic uniform buffer (world transform) — slot 2
	private IBuffer mObjectUniformBuffer ~ { if (_ != null) delete _; };
	private IBindGroupLayout mObjectBindGroupLayout ~ { if (_ != null) delete _; };
	private IBindGroup mObjectBindGroup ~ { if (_ != null) delete _; };

	// Shadow mapping
	private ShadowMap mShadowMap ~ { if (_ != null) delete _; };
	private ISampler mShadowSampler ~ { if (_ != null) delete _; };

	// Shadow pass uniform buffer and bind group (per-cascade dynamic offsets)
	private IBuffer mShadowFrameBuffer ~ { if (_ != null) delete _; };
	private IBindGroupLayout mShadowFrameBindGroupLayout ~ { if (_ != null) delete _; };
	private IBindGroup mShadowFrameBindGroup ~ { if (_ != null) delete _; };

	// Empty bind group for shadow pass slot 0 (no material bindings)
	private IBindGroupLayout mEmptyBindGroupLayout ~ { if (_ != null) delete _; };
	private IBindGroup mEmptyBindGroup ~ { if (_ != null) delete _; };

	// Bone matrix bind group layout (slot 3, for skinned meshes)
	private IBindGroupLayout mBoneBindGroupLayout ~ { if (_ != null) delete _; };

	// Tone mapping pipeline (cached, created on first use)
	private IRenderPipeline mToneMapPipeline;

	// Debug line rendering pipelines (cached, created on first use)
	private IRenderPipeline mDebugDepthPipeline;
	private IRenderPipeline mDebugNoDepthPipeline;

	// Skybox rendering (cached, created on first use)
	private IRenderPipeline mSkyboxPipeline;
	private IBindGroupLayout mSkyboxBindGroupLayout ~ { if (_ != null) delete _; };
	private ISampler mLinearSampler ~ { if (_ != null) delete _; };

	// Asset hot-reloading
	private FileWatcher mFileWatcher ~ { if (_ != null) delete _; };

	// GPU instancing
	private IBuffer mInstanceBuffer ~ { if (_ != null) delete _; };
	private int32 mInstanceBufferCapacity = 0;
	private const int32 MAX_INSTANCES_PER_DRAW = 256;
	private const int32 INSTANCE_STRIDE = 64; // 4 x float4 = world matrix

	// Dynamic uniform buffer alignment for shadow cascade slots (ceil(800/256)*256)
	private const int32 SHADOW_FRAME_ALIGN = 1024;

	// Per-frame command buffers (deferred deletion for GPU sync)
	private const int MAX_FRAMES_IN_FLIGHT = FrameConfig.MAX_FRAMES_IN_FLIGHT;
	private ICommandBuffer[MAX_FRAMES_IN_FLIGHT] mCommandBuffers;

	// Current render target format (set per-viewport, used when creating pipelines)
	private TextureFormat mCurrentColorFormat = .BGRA8UnormSrgb;

	// Frame tracking
	private uint64 mFrameNumber = 0;
	private uint64 mLastUpdateFrame = 0;
	private float mTotalTime = 0;

	// Per-frame render statistics
	private int32 mStatDrawCalls = 0;
	private int32 mStatOpaqueCount = 0;
	private int32 mStatTransparentCount = 0;
	private int32 mStatVisibleGeometry = 0;
	private int32 mStatVisibleLights = 0;
	private int32 mStatShadowCasters = 0;

	// Default backbuffer dimensions (set by application)
	private int32 mBackbufferWidth = 1920;
	private int32 mBackbufferHeight = 1080;

	// Logging
	private ILogger mLogger;

	// ===== Construction =====

	public this(ILogger logger = null)
	{
		mLogger = logger;
	}

	/// Initializes the renderer with a GPU device.
	/// Must be called before any rendering occurs.
	/// shaderPaths: directories containing shader source files.
	public Result<void> Initialize(IDevice device, Span<StringView> shaderPaths = default)
	{
		if (device == null)
			return .Err;

		mDevice = device;
		mResourcePool = new TransientResourcePool(device);
		mRenderGraph = new RenderGraph(mResourcePool);

		// Initialize shader system
		mShaderSystem = new ShaderSystem();
		if (mShaderSystem.Initialize(device, shaderPaths) case .Err)
		{
			mLogger?.LogError("Failed to initialize shader system.");
			return .Err;
		}

		// Initialize material system
		mMaterialSystem = new MaterialSystem();
		if (mMaterialSystem.Initialize(device) case .Err)
		{
			mLogger?.LogError("Failed to initialize material system.");
			return .Err;
		}

		// Initialize pipeline cache
		mPipelineCache = new PipelineStateCache(device, mShaderSystem);

		// Create a default zone with fallback ambient/fog settings
		mDefaultZone = new Zone();
		mDefaultZone.AmbientColor = .(0.2f, 0.2f, 0.2f, 1.0f);
		mDefaultZone.FogColor = .(0.5f, 0.5f, 0.7f, 1.0f);
		mDefaultZone.FogStart = 250.0f;
		mDefaultZone.FogEnd = 1000.0f;

		// Create shadow map atlas and comparison sampler (before bind groups)
		mShadowMap = new ShadowMap(device, 2048);
		if (mShadowMap.CreateAtlas() case .Err)
			mLogger?.LogWarning("Failed to create shadow atlas. Shadows disabled.");

		var shadowSamplerDesc = SamplerDescriptor();
		shadowSamplerDesc.MinFilter = .Linear;
		shadowSamplerDesc.MagFilter = .Linear;
		shadowSamplerDesc.MipmapFilter = .Nearest;
		shadowSamplerDesc.AddressModeU = .ClampToEdge;
		shadowSamplerDesc.AddressModeV = .ClampToEdge;
		shadowSamplerDesc.Compare = .LessEqual;
		shadowSamplerDesc.Label = "ShadowSampler";
		if (mDevice.CreateSampler(&shadowSamplerDesc) case .Ok(let sampler))
			mShadowSampler = sampler;

		// Create per-frame and per-object uniform buffers (uses shadow atlas for bind group)
		if (!CreateUniformBuffers())
		{
			mLogger?.LogError("Failed to create uniform buffers.");
			return .Err;
		}

		// Set up shader hot-reloading via FileWatcher
		SetupShaderHotReload(shaderPaths);

		mLogger?.LogInformation("Renderer initialized.");
		return .Ok;
	}

	/// Shuts down the renderer and releases GPU resources.
	public void Shutdown()
	{
		if (mDevice != null)
			mDevice.WaitIdle();

		// Clean up in-flight command buffers
		for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++)
		{
			if (mCommandBuffers[i] != null)
			{
				delete mCommandBuffers[i];
				mCommandBuffers[i] = null;
			}
		}

		mViewports.Clear();

		if (mPipelineCache != null)
			mPipelineCache.Invalidate();
		if (mMaterialSystem != null)
			mMaterialSystem.ClearCache();

		mLogger?.LogInformation("Renderer shut down.");
	}

	// ===== Shader Hot-Reload =====

	/// Sets up file watching on shader directories for hot-reloading.
	private void SetupShaderHotReload(Span<StringView> shaderPaths)
	{
		if (shaderPaths.Length == 0)
			return;

		mFileWatcher = new FileWatcher();
		mFileWatcher.PollInterval = 1.0f;

		for (let path in shaderPaths)
		{
			if (!path.IsEmpty)
				mFileWatcher.AddDirectory(path, "*.hlsl;*.hlsli", true);
		}

		mFileWatcher.OnFileChanged.Add(new => OnShaderFileChanged);
	}

	/// Called when a shader source file changes on disk.
	/// Invalidates shader and pipeline caches so they recompile on next use.
	private void OnShaderFileChanged(FileChange change)
	{
		if (change.Type == .Deleted)
			return; // Don't invalidate on delete — the shader is gone

		mLogger?.LogInformation("Shader file changed: {}, reloading...", change.Path);

		// Clear compiled shaders so they recompile from source
		if (mShaderSystem != null)
			mShaderSystem.ClearMemoryCache();

		// Invalidate all pipelines (they reference old shader modules)
		if (mPipelineCache != null)
			mPipelineCache.Invalidate();

		// Reset lazily-created pipeline references so they get recreated
		mDebugDepthPipeline = null;
		mDebugNoDepthPipeline = null;
		mSkyboxPipeline = null;
		mToneMapPipeline = null;
	}

	// ===== Viewport Management =====

	/// Number of active viewports.
	public int ViewportCount => mViewports.Count;

	/// Sets the viewport at the given index (grows the list if needed).
	public void SetViewport(int index, Viewport viewport)
	{
		while (mViewports.Count <= index)
			mViewports.Add(null);
		mViewports[index] = viewport;
	}

	/// Gets the viewport at the given index, or null.
	public Viewport GetViewport(int index)
	{
		if (index >= 0 && index < mViewports.Count)
			return mViewports[index];
		return null;
	}

	/// Removes all viewports.
	public void ClearViewports()
	{
		mViewports.Clear();
	}

	/// The GPU device.
	public IDevice Device => mDevice;

	/// The shader system.
	public ShaderSystem ShaderSystem => mShaderSystem;

	/// The material system (GPU resource management for materials).
	public MaterialSystem MaterialSystem => mMaterialSystem;

	/// The pipeline state cache.
	public PipelineStateCache PipelineCache => mPipelineCache;

	/// The default zone used when a drawable is not inside any zone.
	public Zone DefaultZone => mDefaultZone;

	/// The per-frame bind group layout (slot 1).
	public IBindGroupLayout FrameBindGroupLayout => mFrameBindGroupLayout;

	/// The per-object bind group layout (slot 2).
	public IBindGroupLayout ObjectBindGroupLayout => mObjectBindGroupLayout;

	/// Per-frame render statistics.
	public int32 StatDrawCalls => mStatDrawCalls;
	public int32 StatOpaqueBatches => mStatOpaqueCount;
	public int32 StatTransparentBatches => mStatTransparentCount;
	public int32 StatVisibleGeometry => mStatVisibleGeometry;
	public int32 StatVisibleLights => mStatVisibleLights;
	public int32 StatPipelinesCached => mPipelineCache != null ? (int32)mPipelineCache.Count : 0;

	/// Pushes render statistics into a DebugHud for display.
	public void UpdateDebugStats(DebugHud hud)
	{
		if (hud == null)
			return;
		hud.SetStat("Draw Calls", mStatDrawCalls);
		hud.SetStat("Opaque Batches", mStatOpaqueCount);
		hud.SetStat("Transparent Batches", mStatTransparentCount);
		hud.SetStat("Visible Geometry", mStatVisibleGeometry);
		hud.SetStat("Visible Lights", mStatVisibleLights);
		hud.SetStat("Shadow Casters", mStatShadowCasters);
		hud.SetStat("Cached Pipelines", StatPipelinesCached);
	}

	/// Sets the default backbuffer dimensions (used when a viewport targets the swapchain).
	/// Call this when the window/swapchain is created or resized.
	public void SetBackbufferSize(int32 width, int32 height)
	{
		mBackbufferWidth = Math.Max(width, 1);
		mBackbufferHeight = Math.Max(height, 1);
	}

	// ===== Per-Frame Update =====

	/// Updates the rendering state for the current frame.
	/// Called during the RenderUpdate phase of the engine loop.
	///
	/// For each viewport:
	///   1. Updates the octree (reinsert moved drawables)
	///   2. Culls the scene with the camera frustum
	///   3. Collects source batches from visible drawables
	///   4. Assigns lights to drawables
	///   5. Sorts batches for rendering
	///
	public void Update(float timeStep)
	{
		mFrameNumber++;
		mTotalTime += timeStep;

		// Reset per-frame stats
		mStatDrawCalls = 0;
		mStatOpaqueCount = 0;
		mStatTransparentCount = 0;
		mStatVisibleGeometry = 0;
		mStatVisibleLights = 0;
		mStatShadowCasters = 0;

		// Poll for shader/asset file changes
		if (mFileWatcher != null)
			mFileWatcher.Update(timeStep);

		for (let viewport in mViewports)
		{
			if (viewport == null || viewport.Scene == null || viewport.Camera == null)
				continue;

			let scene = viewport.Scene;
			let camera = viewport.Camera;
			let octree = scene.GetComponent<Octree>();
			if (octree == null)
				continue;

			// Ensure camera Y-flip matches the graphics backend requirement
			camera.FlipY = mDevice.FlipProjectionRequired;

			// Step 1: Process pending octree updates (moved drawables)
			octree.Update();

			// Step 2: Update camera aspect ratio from viewport
			if (camera.AutoAspectRatio)
			{
				int32 vpWidth = 0;
				int32 vpHeight = 0;
				GetViewportDimensions(viewport, out vpWidth, out vpHeight);
				if (vpWidth > 0 && vpHeight > 0)
					camera.SetAspectRatioFromViewport(vpWidth, vpHeight);
			}

			// Step 3: Frustum cull
			let frustum = camera.Frustum;
			let cameraPos = camera.Node != null ? camera.Node.WorldPosition : Vector3.Zero;

			mVisibleGeometry.Clear();
			mVisibleLights.Clear();
			mVisibleZones.Clear();

			octree.QueryFrustum(frustum, mVisibleGeometry, .Geometry, camera.ViewMask);
			octree.QueryFrustum(frustum, mVisibleLights, .Light, camera.ViewMask);
			octree.QueryFrustum(frustum, mVisibleZones, .Zone, camera.ViewMask);

			// Step 4: Distance culling and zone assignment
			FrameInfo frameInfo = .()
			{
				FrameNumber = mFrameNumber,
				TimeStep = timeStep,
				ViewportWidth = 0,
				ViewportHeight = 0,
				Camera = camera
			};
			GetViewportDimensions(viewport, out frameInfo.ViewportWidth, out frameInfo.ViewportHeight);

			ProcessVisibleDrawables(mVisibleGeometry, cameraPos, frameInfo);

			// Step 5: Collect light list
			mLightList.Clear();
			for (let drawable in mVisibleLights)
			{
				if (let light = drawable as Light)
					mLightList.Add(light);
			}

			// Step 6: Collect and sort batches
			CollectAndSortBatches(mVisibleGeometry, cameraPos, frameInfo);

			// Capture per-frame statistics
			mStatVisibleGeometry = (int32)mVisibleGeometry.Count;
			mStatVisibleLights = (int32)mVisibleLights.Count;
			mStatOpaqueCount = (int32)mOpaqueBatches.Count;
			mStatTransparentCount = (int32)mTransparentBatches.Count;
		}

		mLastUpdateFrame = mFrameNumber;
	}

	// ===== Rendering =====

	/// Builds and executes the render graph for the current frame.
	/// Call this after Update() to submit GPU work.
	public void Render()
	{
		if (mDevice == null || mRenderGraph == null)
			return;

		// Skip rendering if Update() wasn't called this frame
		if (mLastUpdateFrame != mFrameNumber)
			return;

		mResourcePool.BeginFrame();

		for (let viewport in mViewports)
		{
			if (viewport == null || viewport.Scene == null || viewport.Camera == null)
				continue;

			RenderViewport(viewport);
		}
	}

	/// Builds and executes the render graph for the current frame,
	/// presenting the final result to the swap chain.
	public void Render(ISwapChain swapChain)
	{
		if (mDevice == null || mRenderGraph == null)
			return;

		// Skip rendering if Update() wasn't called this frame
		if (mLastUpdateFrame != mFrameNumber)
			return;

		// Acquire next swapchain image — waits for in-flight fence (GPU done with this slot)
		if (swapChain.AcquireNextImage() case .Err)
			return;

		let frameIndex = (int)swapChain.CurrentFrameIndex;

		// Delete previous command buffer for this frame slot (GPU is done with it after fence wait)
		if (mCommandBuffers[frameIndex] != null)
		{
			delete mCommandBuffers[frameIndex];
			mCommandBuffers[frameIndex] = null;
		}

		mResourcePool.BeginFrame();

		for (let viewport in mViewports)
		{
			if (viewport == null || viewport.Scene == null || viewport.Camera == null)
				continue;

			RenderViewport(viewport, swapChain, frameIndex);
		}

		// Present the rendered image
		swapChain.Present();
	}

	// ===== Private: Viewport Rendering =====

	/// Renders a single viewport by building and executing its render graph.
	private void RenderViewport(Viewport viewport, ISwapChain swapChain = null, int frameIndex = 0)
	{
		mRenderGraph.Reset();

		// Set current color format from swap chain (used when creating pipelines)
		if (swapChain != null)
			mCurrentColorFormat = swapChain.Format;

		let camera = viewport.Camera;
		let cameraPos = camera.Node != null ? camera.Node.WorldPosition : Vector3.Zero;

		// Determine the zone for global rendering state
		let zone = FindBestZone(cameraPos) ?? mDefaultZone;

		// Compute shadow cascades for the first directional shadow-casting light
		ComputeShadowCascades(camera);

		// Upload per-cascade shadow VP matrices to the shadow dynamic uniform buffer
		UploadShadowUniforms();

		// Upload per-frame uniform data (camera, lights, zone, shadow matrices)
		UploadFrameUniforms(camera, zone, cameraPos);

		// Upload per-object uniform data (world transforms for all batches)
		UploadObjectUniforms(mOpaqueBatches, 0);
		UploadObjectUniforms(mTransparentBatches, (int32)mOpaqueBatches.Count);

		// Upload bone matrices for visible animated models
		UploadBoneMatrices();

		// Upload billboard/particle vertex data
		UploadBillboardBuffers();

		// Upload terrain vertex data
		UploadTerrainBuffers();

		// Upload decal geometry
		UploadDecalBuffers();

		// Upload ribbon trail, sprite, and procedural geometry
		UploadDynamicGeometryBuffers();

		// Prepare debug renderer (upload vertex data, ensure pipelines exist)
		let debugRenderer = viewport.Scene.GetComponent<DebugRenderer>();
		let hasDebug = debugRenderer != null && debugRenderer.HasContent;
		if (hasDebug)
		{
			EnsureDebugPipelines();
			debugRenderer.SetPipelines(mDebugDepthPipeline, mDebugNoDepthPipeline);
			debugRenderer.UpdateBuffers(mDevice);
		}

		// Prepare skybox (find in visible geometry, create buffers and bind group)
		Skybox skybox = null;
		for (let drawable in mVisibleGeometry)
		{
			if (let sb = drawable as Skybox)
			{
				skybox = sb;
				break;
			}
		}
		if (skybox != null && skybox.CubemapView != null)
		{
			EnsureSkyboxPipeline();
			skybox.CreateBuffers(mDevice);
			skybox.EnsureBindGroup(mDevice, mSkyboxBindGroupLayout, mLinearSampler);
		}

		// Determine viewport dimensions for transient resource creation
		int32 vpWidth = 0, vpHeight = 0;
		if (swapChain != null)
		{
			vpWidth = (int32)swapChain.Width;
			vpHeight = (int32)swapChain.Height;
		}
		else
		{
			GetViewportDimensions(viewport, out vpWidth, out vpHeight);
		}

		// Import the render target
		ResourceHandle colorTarget;
		if (swapChain != null)
		{
			let backbufferTexture = swapChain.CurrentTexture;
			let backbufferView = swapChain.CurrentTextureView;
			if (backbufferTexture != null && backbufferView != null)
				colorTarget = mRenderGraph.ImportTexture("Backbuffer", backbufferTexture, backbufferView, .Undefined);
			else
				return;
		}
		else if (viewport.RenderTarget != null)
		{
			colorTarget = mRenderGraph.ImportTexture("RenderTarget", null, viewport.RenderTarget, .Undefined);
		}
		else
			return; // No target

		// Create transient depth buffer
		let depthDesc = TextureDescriptor.Texture2D((uint32)vpWidth, (uint32)vpHeight, .Depth32Float, .DepthStencil);
		let depthTarget = mRenderGraph.CreateTexture("DepthBuffer", depthDesc);

		// When post-processing is enabled, render the scene to an HDR intermediate texture
		// instead of directly to the backbuffer. The post-process stack will then
		// read from the HDR texture and write the final LDR result to the backbuffer.
		let hasPostProcess = viewport.PostProcessStack != null && viewport.PostProcessStack.Count > 0;
		ResourceHandle sceneColor = colorTarget;
		if (hasPostProcess)
		{
			let hdrDesc = TextureDescriptor.Texture2D((uint32)vpWidth, (uint32)vpHeight, .RGBA16Float, .RenderTarget | .Sampled);
			sceneColor = mRenderGraph.CreateTexture("SceneHDR", hdrDesc);
		}

		// --- Build render graph passes ---

		// Import shadow atlas into the render graph (always, so transitions are tracked even when no shadow pass runs)
		ResourceHandle shadowAtlas = default;
		bool hasShadowAtlas = mShadowMap != null && mShadowMap.AtlasTexture != null;
		if (hasShadowAtlas)
			shadowAtlas = mRenderGraph.ImportTexture("ShadowAtlas",
				mShadowMap.AtlasTexture, mShadowMap.AtlasView, .Undefined);

		// Pass 0: Shadow depth pass (renders shadow casters from each cascade's perspective)
		if (hasShadowAtlas && mShadowMap.Cascades.Count > 0)
		{

			let cascadeCount = (int32)Math.Min(mShadowMap.Cascades.Count, RenderConstants.MAX_SHADOW_CASCADES);
			let atlasSize = mShadowMap.AtlasSize;

			// Create shadow pipeline configs for each vertex layout that may appear
			PipelineConfig MakeShadowConfig(VertexLayoutType layout)
			{
				var cfg = PipelineConfig();
				cfg.ShaderName = "shadow";
				cfg.ShaderFlags = .CastShadows;
				cfg.VertexLayout = layout;
				cfg.DepthOnly = true;
				cfg.DepthMode = .ReadWrite;
				cfg.DepthFormat = .Depth32Float;
				cfg.ColorTargetCount = 0;
				cfg.DepthBias = 2;
				cfg.DepthBiasSlopeScale = 2.0f;
				cfg.CullMode = .Front;
				return cfg;
			}

			// Pre-resolve shadow pipelines for Mesh (48 bytes) and MeshNoTangent (32 bytes) strides
			IRenderPipeline shadowPipelineMesh = null;
			IRenderPipeline shadowPipelineNoTangent = null;
			if (mPipelineCache.GetOrCreate(MakeShadowConfig(.Mesh), mEmptyBindGroupLayout,
				mShadowFrameBindGroupLayout, mObjectBindGroupLayout) case .Ok(let meshPl))
				shadowPipelineMesh = meshPl;
			if (mPipelineCache.GetOrCreate(MakeShadowConfig(.MeshNoTangent), mEmptyBindGroupLayout,
				mShadowFrameBindGroupLayout, mObjectBindGroupLayout) case .Ok(let noTangentPl))
				shadowPipelineNoTangent = noTangentPl;

			mRenderGraph.AddRasterPass("ShadowPass",
				new [=shadowAtlas] (builder) => {
					builder.SetDepthStencilAttachment(shadowAtlas, .Clear, 1.0f);
					builder.SideEffect();
				},
				new (encoder) => {
					if (shadowPipelineMesh == null)
						return;

					// Bind empty material at slot 0 (shadow shader uses no material bindings)
					if (mEmptyBindGroup != null)
						encoder.SetBindGroup(0, mEmptyBindGroup);

					for (int32 c = 0; c < cascadeCount; c++)
					{
						// Set viewport and scissor for this cascade's region in the atlas
						let cascadeWidth = (float)atlasSize / (float)cascadeCount;
						encoder.SetViewport(cascadeWidth * (float)c, 0, cascadeWidth, (float)atlasSize, 0.0f, 1.0f);
						encoder.SetScissorRect((int32)(cascadeWidth * (float)c), 0, (uint32)cascadeWidth, atlasSize);

						// Bind shadow frame uniforms with dynamic offset for this cascade's VP matrix
						if (mShadowFrameBindGroup != null)
						{
							uint32[1] dynOff = .((uint32)(c * SHADOW_FRAME_ALIGN));
							encoder.SetBindGroup(1, mShadowFrameBindGroup, Span<uint32>(&dynOff[0], 1));
						}

						// Draw all opaque shadow casters, selecting the correct shadow pipeline per vertex layout
						IRenderPipeline lastShadowPipeline = null;
						int32 idx = 0;
						for (let batch in mOpaqueBatches)
						{
							// Determine the correct shadow pipeline from the batch's vertex layout
							var shadowPl = shadowPipelineMesh; // default
							if (batch.Material != null && batch.Material.Material != null)
							{
								let batchLayout = batch.Material.Material.PipelineConfig.VertexLayout;
								if (batchLayout == .MeshNoTangent)
									shadowPl = shadowPipelineNoTangent;
							}

							// Only switch pipeline when the layout changes (minimize state changes)
							if (shadowPl != lastShadowPipeline)
							{
								encoder.SetPipeline(shadowPl);
								lastShadowPipeline = shadowPl;
							}

							DrawShadowBatch(encoder, batch, idx);
							idx++;
						}
					}
				}
			);
		}

		// Pass 1: Clear + Opaque geometry (depth write enabled)
		let fogColor = zone.FogColor;
		mRenderGraph.AddRasterPass("OpaquePass",
			new [=sceneColor, =depthTarget, =fogColor, =hasShadowAtlas, =shadowAtlas] (builder) => {
				builder.SetColorAttachment(0, sceneColor, .Clear, fogColor);
				builder.SetDepthStencilAttachment(depthTarget, .Clear, 1.0f);
				// Declare read dependency on shadow atlas so the render graph inserts
				// the depth-attachment → shader-read-only barrier (or undefined → shader-read-only
				// when no shadow pass ran).
				if (hasShadowAtlas)
					builder.Read(shadowAtlas);
				builder.SideEffect();
			},
			new (encoder) => {
				// Set viewport and scissor for the full render target
				encoder.SetViewport(0, 0, (float)vpWidth, (float)vpHeight, 0.0f, 1.0f);
				encoder.SetScissorRect(0, 0, (uint32)vpWidth, (uint32)vpHeight);

				// Bind per-frame uniforms once for the pass
				if (mFrameBindGroup != null)
					encoder.SetBindGroup(1, mFrameBindGroup);

				// Draw opaque batches with GPU instancing where possible
				DrawOpaqueBatchesInstanced(encoder);

				// Draw skybox last in opaque pass (depth = 1.0, fills uncovered pixels)
				if (skybox != null && mSkyboxPipeline != null && skybox.BindGroup != null)
				{
					encoder.SetPipeline(mSkyboxPipeline);
					encoder.SetBindGroup(0, skybox.BindGroup);
					if (mFrameBindGroup != null)
						encoder.SetBindGroup(1, mFrameBindGroup);
					encoder.SetVertexBuffer(0, skybox.VertexBuffer);
					encoder.SetIndexBuffer(skybox.IndexBuffer, .UInt16);
					encoder.DrawIndexed(36, 1, 0, 0, 0);
				}

				// Draw depth-tested debug lines
				if (hasDebug)
				{
					if (mEmptyBindGroup != null)
						encoder.SetBindGroup(0, mEmptyBindGroup);
					if (mFrameBindGroup != null)
						encoder.SetBindGroup(1, mFrameBindGroup);
					debugRenderer.RenderDepthLines(encoder);
				}
			}
		);

		// Pass 2: Transparent geometry (back-to-front, depth read-only)
		mRenderGraph.AddRasterPass("TransparentPass",
			new [=sceneColor, =depthTarget] (builder) => {
				builder.SetColorAttachment(0, sceneColor, .Load);
				builder.SetDepthStencilAttachment(depthTarget, .Load, 1.0f, readOnly: true);
				builder.SideEffect();
			},
			new (encoder) => {
				// Set viewport and scissor for the full render target
				encoder.SetViewport(0, 0, (float)vpWidth, (float)vpHeight, 0.0f, 1.0f);
				encoder.SetScissorRect(0, 0, (uint32)vpWidth, (uint32)vpHeight);

				// Bind per-frame uniforms once for the pass
				if (mFrameBindGroup != null)
					encoder.SetBindGroup(1, mFrameBindGroup);

				// Draw transparent batches back-to-front
				int32 idx = (int32)mOpaqueBatches.Count;
				for (let batch in mTransparentBatches)
				{
					DrawBatch(encoder, batch, idx);
					idx++;
				}

				// Draw overlay (no depth test) debug lines
				if (hasDebug)
				{
					if (mEmptyBindGroup != null)
						encoder.SetBindGroup(0, mEmptyBindGroup);
					if (mFrameBindGroup != null)
						encoder.SetBindGroup(1, mFrameBindGroup);
					debugRenderer.RenderNoDepthLines(encoder);
				}
			}
		);

		// Pass 3: Post-processing (HDR → LDR → backbuffer)
		if (hasPostProcess)
		{
			EnsurePostProcessResources(viewport.PostProcessStack);
			viewport.PostProcessStack.Apply(mRenderGraph, sceneColor, colorTarget, (uint32)vpWidth, (uint32)vpHeight);
		}

		// Compile and execute
		if (mRenderGraph.Compile(mDevice) case .Err)
		{
			mLogger?.LogError("Failed to compile render graph.");
			return;
		}

		ICommandBuffer cmdBuffer = null;
		if (swapChain != null)
			cmdBuffer = mRenderGraph.Execute(mDevice, swapChain);
		else
			cmdBuffer = mRenderGraph.Execute(mDevice);

		// Store command buffer for deferred deletion (GPU still using it)
		if (cmdBuffer != null)
		{
			if (mCommandBuffers[frameIndex] != null)
				delete mCommandBuffers[frameIndex];
			mCommandBuffers[frameIndex] = cmdBuffer;
		}
	}

	// ===== Private: Draw =====

	/// Issues draw commands for a single source batch.
	/// objectIndex: index into the per-object dynamic uniform buffer.
	private void DrawBatch(IRenderPassEncoder encoder, SourceBatch batch, int32 objectIndex)
	{
		if (batch.VertexBuffer == null || batch.IndexBuffer == null)
			return;
		if (batch.IndexCount <= 0)
			return;
		if (batch.Material == null || batch.Material.Material == null)
			return;

		let isSkinned = batch.BoneMatrixBuffer != null;

		// Bind pipeline from material's PipelineConfig
		if (batch.Material != null && batch.Material.Material != null)
		{
			let mat = batch.Material;
			var pipelineConfig = mat.Material.PipelineConfig;

			// Override color format to match the actual render target
			pipelineConfig.ColorFormat = mCurrentColorFormat;

			// Override for skinned meshes: use SkinnedMesh layout and Skinned shader variant
			if (isSkinned)
			{
				pipelineConfig.ShaderFlags |= .Skinned;
				pipelineConfig.VertexLayout = .SkinnedMesh;
			}

			// Get or create material layout and bind group
			let layoutResult = mMaterialSystem.GetOrCreateLayout(mat.Material);
			IBindGroupLayout materialLayout = null;
			if (layoutResult case .Ok(let layout))
				materialLayout = layout;

			// Ensure material GPU resources are up to date
			if(mMaterialSystem.PrepareInstance(mat, materialLayout) not case .Ok)
				return;

			// Get or create the pipeline (with bone layout at slot 3 for skinned meshes)
			IBindGroupLayout boneLayout = isSkinned ? mBoneBindGroupLayout : null;
			if (mPipelineCache.GetOrCreate(pipelineConfig, materialLayout,
				mFrameBindGroupLayout, mObjectBindGroupLayout, boneLayout) case .Ok(let pipeline))
				encoder.SetPipeline(pipeline);

			// Bind material bind group at slot 0
			let bindGroup = mMaterialSystem.GetBindGroup(mat);
			if (bindGroup != null)
				encoder.SetBindGroup(0, bindGroup);
		}

		// Bind per-frame uniforms at slot 1
		if (mFrameBindGroup != null)
			encoder.SetBindGroup(1, mFrameBindGroup);

		// Bind per-object uniforms at slot 2 with dynamic offset
		if (mObjectBindGroup != null)
		{
			uint32[1] dynamicOffsets = .((uint32)(objectIndex * RenderConstants.OBJECT_UNIFORM_ALIGN));
			encoder.SetBindGroup(2, mObjectBindGroup, Span<uint32>(&dynamicOffsets[0], 1));
		}

		// Bind bone matrices at slot 3 for skinned meshes
		if (isSkinned && batch.Drawable != null)
		{
			if (let animModel = batch.Drawable as AnimatedModel)
			{
				if (animModel.BoneBindGroup != null)
					encoder.SetBindGroup(3, animModel.BoneBindGroup);
			}
		}

		encoder.SetVertexBuffer(0, batch.VertexBuffer);
		encoder.SetIndexBuffer(batch.IndexBuffer, batch.IndexBufferFormat);
		encoder.DrawIndexed((uint32)batch.IndexCount, 1, (uint32)batch.StartIndex, 0, 0);
		mStatDrawCalls++;
	}

	/// Issues draw commands for a single shadow caster batch.
	/// Pipeline, material (slot 0), and frame uniforms (slot 1) are already bound by the caller.
	/// This method only binds per-object uniforms (slot 2) and issues the draw call.
	private void DrawShadowBatch(IRenderPassEncoder encoder, SourceBatch batch, int32 objectIndex)
	{
		if (batch.VertexBuffer == null || batch.IndexBuffer == null)
			return;
		if (batch.IndexCount <= 0)
			return;

		// Skip non-shadow-casting drawables
		if (batch.Drawable != null && !batch.Drawable.CastShadows)
			return;

		// Bind per-object uniforms at slot 2 with dynamic offset
		if (mObjectBindGroup != null)
		{
			uint32[1] dynamicOffsets = .((uint32)(objectIndex * RenderConstants.OBJECT_UNIFORM_ALIGN));
			encoder.SetBindGroup(2, mObjectBindGroup, Span<uint32>(&dynamicOffsets[0], 1));
		}

		encoder.SetVertexBuffer(0, batch.VertexBuffer);
		encoder.SetIndexBuffer(batch.IndexBuffer, batch.IndexBufferFormat);
		encoder.DrawIndexed((uint32)batch.IndexCount, 1, (uint32)batch.StartIndex, 0, 0);
		mStatDrawCalls++;
		mStatShadowCasters++;
	}

	// ===== GPU Instancing =====

	/// Key for grouping batches that can be instanced together.
	private struct InstanceGroupKey : IHashable, IEquatable<InstanceGroupKey>
	{
		public IBuffer VertexBuffer;
		public IBuffer IndexBuffer;
		public int32 StartIndex;
		public int32 IndexCount;
		public MaterialInstance Material;

		public int GetHashCode()
		{
			int hash = Internal.UnsafeCastToPtr(VertexBuffer).GetHashCode();
			hash = hash * 31 + Internal.UnsafeCastToPtr(IndexBuffer).GetHashCode();
			hash = hash * 31 + StartIndex;
			hash = hash * 31 + IndexCount;
			hash = hash * 31 + Internal.UnsafeCastToPtr(Material).GetHashCode();
			return hash;
		}

		public bool Equals(InstanceGroupKey other)
		{
			return VertexBuffer === other.VertexBuffer &&
				IndexBuffer === other.IndexBuffer &&
				StartIndex == other.StartIndex &&
				IndexCount == other.IndexCount &&
				Material === other.Material;
		}
	}

	/// Ensures the instance buffer can hold at least the given number of instances.
	private void EnsureInstanceBuffer(int32 instanceCount)
	{
		if (mInstanceBuffer != null && mInstanceBufferCapacity >= instanceCount)
			return;

		if (mInstanceBuffer != null)
		{
			delete mInstanceBuffer;
			mInstanceBuffer = null;
		}

		let size = (uint64)(instanceCount * INSTANCE_STRIDE);
		BufferDescriptor desc = .(size, .Vertex | .CopyDst);
		if (mDevice.CreateBuffer(&desc) case .Ok(let buf))
		{
			mInstanceBuffer = buf;
			mInstanceBufferCapacity = instanceCount;
		}
	}

	/// Draws opaque batches with instancing where possible.
	/// Batches sharing the same mesh+material are grouped and drawn with a single instanced call.
	/// Batches that can't be instanced (skinned, unique geometry) fall through to regular DrawBatch.
	private void DrawOpaqueBatchesInstanced(IRenderPassEncoder encoder)
	{
		if (mOpaqueBatches.Count == 0)
			return;

		// Group instanceable batches by key
		let groups = scope Dictionary<InstanceGroupKey, List<int32>>();
		let singleBatches = scope List<int32>(); // Batches that can't be instanced

		for (int32 i = 0; i < (int32)mOpaqueBatches.Count; i++)
		{
			let batch = mOpaqueBatches[i];

			// Skip batches that can't be instanced:
			// - Skinned meshes (need per-instance bone matrices)
			// - Batches without material
			// - Batches without buffers
			if (batch.BoneMatrixBuffer != null || batch.Material == null ||
				batch.VertexBuffer == null || batch.IndexBuffer == null)
			{
				singleBatches.Add(i);
				continue;
			}

			InstanceGroupKey key = .()
			{
				VertexBuffer = batch.VertexBuffer,
				IndexBuffer = batch.IndexBuffer,
				StartIndex = batch.StartIndex,
				IndexCount = batch.IndexCount,
				Material = batch.Material
			};

			if (!groups.ContainsKey(key))
				groups[key] = scope:: List<int32>();
			groups[key].Add(i);
		}

		// Draw instanced groups (groups with 2+ batches)
		for (let kv in groups)
		{
			let batchIndices = kv.value;
			if (batchIndices.Count < 2)
			{
				// Single batch — draw normally
				DrawBatch(encoder, mOpaqueBatches[batchIndices[0]], batchIndices[0]);
				continue;
			}

			let count = Math.Min((int32)batchIndices.Count, MAX_INSTANCES_PER_DRAW);
			EnsureInstanceBuffer(count);
			if (mInstanceBuffer == null)
			{
				// Fallback to individual draws
				for (let idx in batchIndices)
					DrawBatch(encoder, mOpaqueBatches[idx], idx);
				continue;
			}

			// Upload world matrices to instance buffer
			let uploadSize = (uint64)(count * INSTANCE_STRIDE);
			Matrix* matrices = (Matrix*)scope uint8[count * INSTANCE_STRIDE]* (?);
			for (int32 j = 0; j < count; j++)
				matrices[j] = mOpaqueBatches[batchIndices[j]].WorldTransform;
			mDevice.Queue.WriteBuffer(mInstanceBuffer, 0, Span<uint8>((uint8*)matrices, (int)uploadSize));

			// Set up instanced pipeline
			let firstBatch = mOpaqueBatches[batchIndices[0]];
			if (firstBatch.Material != null && firstBatch.Material.Material != null)
			{
				let mat = firstBatch.Material;
				var pipelineConfig = mat.Material.PipelineConfig;
				pipelineConfig.ColorFormat = mCurrentColorFormat;
				pipelineConfig.ShaderFlags |= .Instanced;

				let layoutResult = mMaterialSystem.GetOrCreateLayout(mat.Material);
				IBindGroupLayout materialLayout = null;
				if (layoutResult case .Ok(let layout))
					materialLayout = layout;

				mMaterialSystem.PrepareInstance(mat, materialLayout);

				if (mPipelineCache.GetOrCreate(pipelineConfig, materialLayout,
					mFrameBindGroupLayout, mObjectBindGroupLayout) case .Ok(let pipeline))
					encoder.SetPipeline(pipeline);

				let bindGroup = mMaterialSystem.GetBindGroup(mat);
				if (bindGroup != null)
					encoder.SetBindGroup(0, bindGroup);
			}

			// Bind frame uniforms
			if (mFrameBindGroup != null)
				encoder.SetBindGroup(1, mFrameBindGroup);

			// Bind per-object uniforms (slot 2 still needed for pipeline layout compatibility,
			// but INSTANCED shader doesn't read from it)
			if (mObjectBindGroup != null)
			{
				uint32[1] dynamicOffsets = .(0);
				encoder.SetBindGroup(2, mObjectBindGroup, Span<uint32>(&dynamicOffsets[0], 1));
			}

			// Bind vertex buffer (slot 0) and instance buffer (slot 1)
			encoder.SetVertexBuffer(0, firstBatch.VertexBuffer);
			encoder.SetVertexBuffer(1, mInstanceBuffer);
			encoder.SetIndexBuffer(firstBatch.IndexBuffer, firstBatch.IndexBufferFormat);
			encoder.DrawIndexed((uint32)firstBatch.IndexCount, (uint32)count, (uint32)firstBatch.StartIndex, 0, 0);
			mStatDrawCalls++;
		}

		// Draw non-instanceable batches normally
		for (let idx in singleBatches)
			DrawBatch(encoder, mOpaqueBatches[idx], idx);
	}

	/// Computes shadow cascades for the first directional shadow-casting light.
	private void ComputeShadowCascades(Camera camera)
	{
		if (mShadowMap == null)
			return;

		// Find the first directional light that casts shadows
		Light shadowLight = null;
		for (let light in mLightList)
		{
			if (light.LightType == .Directional && light.CastShadows)
			{
				shadowLight = light;
				break;
			}
		}

		if (shadowLight != null)
			mShadowMap.ComputeDirectionalCascades(camera, shadowLight);
		else
			mShadowMap.Cascades.Clear();
	}

	// ===== Private: Culling & Sorting =====

	/// Processes visible drawables: computes distances, culls by draw distance,
	/// assigns zones, and calls UpdateBatches.
	private void ProcessVisibleDrawables(List<Drawable> drawables, Vector3 cameraPos, FrameInfo frameInfo)
	{
		for (int i = drawables.Count - 1; i >= 0; i--)
		{
			let drawable = drawables[i];

			// Skip already-processed drawables
			if (drawable.WasProcessedThisFrame(mFrameNumber))
			{
				drawables.RemoveAtFast(i);
				continue;
			}

			// Compute distance from camera
			let bb = drawable.WorldBoundingBox;
			let drawableCenter = (bb.Min + bb.Max) * 0.5f;
			let distance = Vector3.Distance(drawableCenter, cameraPos);
			drawable.SetDistance(distance);

			// Distance culling
			let drawDist = drawable.DrawDistance;
			if (drawDist > 0.0f && distance > drawDist)
			{
				drawables.RemoveAtFast(i);
				continue;
			}

			// Zone assignment
			let zone = FindBestZone(drawableCenter);
			drawable.SetZone(zone ?? mDefaultZone);

			// Mark as processed
			drawable.MarkFrame(mFrameNumber);

			// Update batches
			drawable.UpdateBatches(frameInfo);
		}
	}

	/// Collects source batches from visible drawables and sorts them.
	/// Opaque: front-to-back (to maximize early-Z rejection).
	/// Transparent: back-to-front (for correct blending).
	private void CollectAndSortBatches(List<Drawable> drawables, Vector3 cameraPos, FrameInfo frameInfo)
	{
		mOpaqueBatches.Clear();
		mTransparentBatches.Clear();

		for (let drawable in drawables)
		{
			let batches = drawable.Batches;
			for (let batch in batches)
			{
				bool isTransparent = false;
				if (batch.Material != null && batch.Material.Material != null)
				{
					let blendMode = batch.Material.BlendMode;
					isTransparent = blendMode != .Opaque;
				}

				if (isTransparent)
					mTransparentBatches.Add(batch);
				else
					mOpaqueBatches.Add(batch);
			}
		}

		// Sort opaque front-to-back (smaller distance first)
		mOpaqueBatches.Sort(scope (a, b) => {
			if (a.Distance < b.Distance) return -1;
			if (a.Distance > b.Distance) return 1;
			return 0;
		});

		// Sort transparent back-to-front (larger distance first)
		mTransparentBatches.Sort(scope (a, b) => {
			if (a.Distance > b.Distance) return -1;
			if (a.Distance < b.Distance) return 1;
			return 0;
		});
	}

	/// Finds the highest-priority zone containing the given point.
	private Zone FindBestZone(Vector3 point)
	{
		Zone bestZone = null;
		int32 bestPriority = int32.MinValue;

		for (let drawable in mVisibleZones)
		{
			if (let zone = drawable as Zone)
			{
				if (zone.Contains(point) && zone.Priority > bestPriority)
				{
					bestZone = zone;
					bestPriority = zone.Priority;
				}
			}
		}

		return bestZone;
	}

	// ===== Private: Uniform Buffer Management =====

	/// Creates per-frame and per-object uniform buffers, layouts, and bind groups.
	private bool CreateUniformBuffers()
	{
		// --- Per-frame uniform buffer (800 bytes) ---
		var frameBufDesc = BufferDescriptor(RenderConstants.FRAME_UNIFORM_SIZE, .Uniform | .CopyDst);
		if (mDevice.CreateBuffer(&frameBufDesc) case .Ok(let buf))
			mFrameUniformBuffer = buf;
		else
			return false;

		// Per-frame bind group layout: uniform buffer + shadow atlas texture + comparison sampler
		var compSamplerEntry = BindGroupLayoutEntry();
		compSamplerEntry.Binding = 0;
		compSamplerEntry.Visibility = .Fragment;
		compSamplerEntry.Type = .ComparisonSampler;

		BindGroupLayoutEntry[3] frameLayoutEntries = .(
			.UniformBuffer(0, .Vertex | .Fragment),
			.SampledTexture(0, .Fragment),
			compSamplerEntry
		);
		var frameLayoutDesc = BindGroupLayoutDescriptor(frameLayoutEntries);
		if (mDevice.CreateBindGroupLayout(&frameLayoutDesc) case .Ok(let layout))
			mFrameBindGroupLayout = layout;
		else
			return false;

		// Per-frame bind group (includes shadow atlas if available)
		let shadowAtlasView = (mShadowMap != null) ? mShadowMap.AtlasDepthView : null;
		if (shadowAtlasView != null && mShadowSampler != null)
		{
			BindGroupEntry[3] frameEntries = .(
				.Buffer(0, mFrameUniformBuffer, 0, RenderConstants.FRAME_UNIFORM_SIZE),
				.Texture(0, shadowAtlasView, .ShaderReadOnly),
				.Sampler(0, mShadowSampler)
			);
			var frameBgDesc = BindGroupDescriptor(mFrameBindGroupLayout, frameEntries);
			if (mDevice.CreateBindGroup(&frameBgDesc) case .Ok(let bg))
				mFrameBindGroup = bg;
			else
				return false;
		}
		else
		{
			// Fallback: no shadow atlas available (just uniform buffer)
			// Create a minimal layout and bind group without shadow textures
			if (mFrameBindGroupLayout != null) { delete mFrameBindGroupLayout; mFrameBindGroupLayout = null; }
			BindGroupLayoutEntry[1] minLayoutEntries = .(.UniformBuffer(0, .Vertex | .Fragment));
			var minLayoutDesc = BindGroupLayoutDescriptor(minLayoutEntries);
			if (mDevice.CreateBindGroupLayout(&minLayoutDesc) case .Ok(let minLayout))
				mFrameBindGroupLayout = minLayout;
			else
				return false;

			BindGroupEntry[1] frameEntries = .(.Buffer(0, mFrameUniformBuffer, 0, RenderConstants.FRAME_UNIFORM_SIZE));
			var frameBgDesc = BindGroupDescriptor(mFrameBindGroupLayout, frameEntries);
			if (mDevice.CreateBindGroup(&frameBgDesc) case .Ok(let bg))
				mFrameBindGroup = bg;
			else
				return false;
		}

		// --- Per-object dynamic uniform buffer ---
		let objectBufSize = (uint64)(RenderConstants.MAX_OBJECTS_PER_FRAME * RenderConstants.OBJECT_UNIFORM_ALIGN);
		var objectBufDesc = BufferDescriptor(objectBufSize, .Uniform | .CopyDst);
		if (mDevice.CreateBuffer(&objectBufDesc) case .Ok(let objBuf))
			mObjectUniformBuffer = objBuf;
		else
			return false;

		// Per-object bind group layout: one uniform buffer at binding 0 (vertex only), with dynamic offset
		BindGroupLayoutEntry[1] objectLayoutEntries = .(.UniformBuffer(0, .Vertex, true));
		var objectLayoutDesc = BindGroupLayoutDescriptor(objectLayoutEntries);
		if (mDevice.CreateBindGroupLayout(&objectLayoutDesc) case .Ok(let objLayout))
			mObjectBindGroupLayout = objLayout;
		else
			return false;

		// Per-object bind group (dynamic — offset provided at bind time)
		BindGroupEntry[1] objectEntries = .(.Buffer(0, mObjectUniformBuffer, 0, RenderConstants.OBJECT_UNIFORM_SIZE));
		var objectBgDesc = BindGroupDescriptor(mObjectBindGroupLayout, objectEntries);
		if (mDevice.CreateBindGroup(&objectBgDesc) case .Ok(let objBg))
			mObjectBindGroup = objBg;
		else
			return false;

		// --- Shadow pass dynamic uniform buffer (one slot per cascade, 1024-byte aligned) ---
		let shadowBufSize = (uint64)(RenderConstants.MAX_SHADOW_CASCADES * SHADOW_FRAME_ALIGN);
		var shadowBufDesc = BufferDescriptor(shadowBufSize, .Uniform | .CopyDst);
		if (mDevice.CreateBuffer(&shadowBufDesc) case .Ok(let shadowBuf))
			mShadowFrameBuffer = shadowBuf;
		else
			return false;

		// Shadow frame bind group layout: single dynamic uniform buffer
		BindGroupLayoutEntry[1] shadowLayoutEntries = .(.UniformBuffer(0, .Vertex, true));
		var shadowLayoutDesc = BindGroupLayoutDescriptor(shadowLayoutEntries);
		if (mDevice.CreateBindGroupLayout(&shadowLayoutDesc) case .Ok(let shadowLayout))
			mShadowFrameBindGroupLayout = shadowLayout;
		else
			return false;

		// Shadow frame bind group
		BindGroupEntry[1] shadowEntries = .(.Buffer(0, mShadowFrameBuffer, 0, RenderConstants.FRAME_UNIFORM_SIZE));
		var shadowBgDesc = BindGroupDescriptor(mShadowFrameBindGroupLayout, shadowEntries);
		if (mDevice.CreateBindGroup(&shadowBgDesc) case .Ok(let shadowBg))
			mShadowFrameBindGroup = shadowBg;
		else
			return false;

		// Empty bind group layout and bind group for shadow pass material slot
		var emptyLayoutDesc = BindGroupLayoutDescriptor();
		if (mDevice.CreateBindGroupLayout(&emptyLayoutDesc) case .Ok(let emptyLayout))
			mEmptyBindGroupLayout = emptyLayout;
		else
			return false;

		var emptyBgDesc = BindGroupDescriptor(mEmptyBindGroupLayout, default);
		if (mDevice.CreateBindGroup(&emptyBgDesc) case .Ok(let emptyBg))
			mEmptyBindGroup = emptyBg;
		else
			return false;

		// Bone matrix bind group layout (slot 3): single uniform buffer at binding 0
		BindGroupLayoutEntry[1] boneLayoutEntries = .(.UniformBuffer(0, .Vertex));
		var boneLayoutDesc = BindGroupLayoutDescriptor(boneLayoutEntries);
		if (mDevice.CreateBindGroupLayout(&boneLayoutDesc) case .Ok(let boneLayout))
			mBoneBindGroupLayout = boneLayout;
		else
			return false;

		return true;
	}

	/// Uploads per-frame uniform data to the GPU.
	private void UploadFrameUniforms(Camera camera, Zone zone, Vector3 cameraPos)
	{
		var data = FrameUniformData();

		// Camera matrices
		data.View = camera.ViewMatrix;
		data.Projection = camera.ProjectionMatrix;
		data.ViewProjection = camera.ViewProjectionMatrix;
		data.CameraPositionAndTime = .(cameraPos.X, cameraPos.Y, cameraPos.Z, mTotalTime);

		// Zone ambient and fog
		let ambient = zone.AmbientColor;
		data.AmbientColor = .((float)ambient.R / 255.0f, (float)ambient.G / 255.0f, (float)ambient.B / 255.0f, (float)ambient.A / 255.0f);

		let fogColor = zone.FogColor;
		data.FogParams1 = .((float)fogColor.R / 255.0f, (float)fogColor.G / 255.0f, (float)fogColor.B / 255.0f, zone.FogStart);
		data.FogParams2 = .(zone.FogEnd, 0, (float)mLightList.Count, 0);

		// Pack lights (up to MAX_SHADER_LIGHTS)
		let lightCount = Math.Min(mLightList.Count, RenderConstants.MAX_SHADER_LIGHTS);
		for (int32 i = 0; i < lightCount; i++)
		{
			let light = mLightList[i];
			let pos = light.WorldPosition;
			let dir = light.Direction;
			let col = light.EffectiveColor;

			data.Lights[i].PositionAndRange = .(pos.X, pos.Y, pos.Z, light.Range);
			data.Lights[i].DirectionAndSpotAngle = .(dir.X, dir.Y, dir.Z,
				Math.Cos(light.SpotFov * 0.5f));
			data.Lights[i].ColorAndIntensity = .((float)col.R / 255.0f, (float)col.G / 255.0f, (float)col.B / 255.0f, light.SpecularIntensity);
			data.Lights[i].TypeAndParams = .((float)light.LightType,
				Math.Cos(light.SpotInnerFov * 0.5f), 0, 0);
		}

		// Pack shadow cascade data
		if (mShadowMap != null && mShadowMap.Cascades.Count > 0)
		{
			let cascades = mShadowMap.Cascades;
			let cascadeCount = Math.Min(cascades.Count, RenderConstants.MAX_SHADOW_CASCADES);

			if (cascadeCount > 0) data.ShadowMatrix0 = cascades[0].ViewProjectionMatrix;
			if (cascadeCount > 1) data.ShadowMatrix1 = cascades[1].ViewProjectionMatrix;
			if (cascadeCount > 2) data.ShadowMatrix2 = cascades[2].ViewProjectionMatrix;
			if (cascadeCount > 3) data.ShadowMatrix3 = cascades[3].ViewProjectionMatrix;

			data.ShadowSplits = .(
				cascadeCount > 0 ? cascades[0].SplitFar : 0,
				cascadeCount > 1 ? cascades[1].SplitFar : 0,
				cascadeCount > 2 ? cascades[2].SplitFar : 0,
				cascadeCount > 3 ? cascades[3].SplitFar : 0
			);

			data.ShadowParams = .((float)cascadeCount, 0.005f,
				1.0f / (float)mShadowMap.AtlasSize, 1.0f);
		}
		else
		{
			data.ShadowParams = .(0, 0, 0, 0); // Shadows disabled
		}

		// IBL params from zone's EnvironmentMap
		if (zone.EnvironmentMap != null && zone.EnvironmentMap.IsReady)
		{
			let envMap = zone.EnvironmentMap;
			data.IBLParams = .(envMap.DiffuseIntensity, envMap.SpecularIntensity,
				(float)envMap.PrefilteredMipCount, 1.0f);
		}
		else
		{
			data.IBLParams = .(0, 0, 0, 0); // IBL disabled
		}

		// Upload
		mDevice.Queue.WriteBuffer(mFrameUniformBuffer, 0,
			Span<uint8>((uint8*)&data, sizeof(FrameUniformData)));
	}

	/// Uploads per-object world transforms to the dynamic uniform buffer.
	private void UploadObjectUniforms(List<SourceBatch> batches, int32 startIndex)
	{
		for (int32 i = 0; i < batches.Count; i++)
		{
			let objectIndex = startIndex + i;
			if (objectIndex >= RenderConstants.MAX_OBJECTS_PER_FRAME)
				break;

			var objData = ObjectUniformData();
			objData.World = batches[i].WorldTransform;

			// Upload lightmap UV transform if the drawable is lightmapped
			if (batches[i].Drawable != null && batches[i].Drawable.IsLightmapped)
				objData.LightmapScaleOffset = batches[i].Drawable.LightmapInfo.ScaleOffset;
			else
				objData.LightmapScaleOffset = .(0, 0, 0, 0);

			let offset = (uint64)(objectIndex * RenderConstants.OBJECT_UNIFORM_ALIGN);
			mDevice.Queue.WriteBuffer(mObjectUniformBuffer, offset,
				Span<uint8>((uint8*)&objData, sizeof(ObjectUniformData)));
		}
	}

	/// Uploads bone/skinning matrices to the GPU for all visible AnimatedModels.
	private void UploadBoneMatrices()
	{
		for (let drawable in mVisibleGeometry)
		{
			if (let animModel = drawable as AnimatedModel)
				animModel.UploadBoneMatrices(mDevice, mBoneBindGroupLayout);
		}
	}

	/// Uploads billboard/particle vertex data to the GPU for all visible BillboardSets.
	private void UploadBillboardBuffers()
	{
		for (let drawable in mVisibleGeometry)
		{
			if (let billboardSet = drawable as BillboardSet)
				billboardSet.UploadToGPU(mDevice);
		}
	}

	/// Uploads ribbon trail, sprite, and procedural geometry to the GPU.
	private void UploadDynamicGeometryBuffers()
	{
		for (let drawable in mVisibleGeometry)
		{
			if (let trail = drawable as RibbonTrail)
				trail.UploadToGPU(mDevice);
			else if (let sprite = drawable as Sprite2D)
				sprite.UploadToGPU(mDevice);
			else if (let procGeo = drawable as ProceduralGeometry)
				procGeo.UploadToGPU(mDevice);
		}
	}

	/// Uploads decal geometry to the GPU for all visible DecalSets.
	private void UploadDecalBuffers()
	{
		for (let drawable in mVisibleGeometry)
		{
			if (let decalSet = drawable as DecalSet)
				decalSet.UploadToGPU(mDevice);
		}
	}

	/// Uploads terrain vertex/index data to the GPU for all visible Terrains.
	private void UploadTerrainBuffers()
	{
		for (let drawable in mVisibleGeometry)
		{
			if (let terrain = drawable as Terrain)
				terrain.UploadToGPU(mDevice);
		}
	}

	/// Ensures post-process effects have their GPU resources initialized.
	/// Called lazily before the first frame that uses post-processing.
	private void EnsurePostProcessResources(PostProcessStack stack)
	{
		if (stack == null || mDevice == null)
			return;

		for (int i = 0; i < stack.Count; i++)
		{
			let effect = stack.GetEffect(i);
			if (let toneMap = effect as ToneMapEffect)
			{
				if (toneMap.Pipeline != null)
					continue; // Already initialized

				// Step 1: Initialize the effect's GPU resources (UB, sampler, layout)
				if (toneMap.BindGroupLayout == null)
				{
					if (toneMap.InitializeGPU(mDevice, null) case .Err)
					{
						mLogger?.LogError("Failed to initialize ToneMapEffect GPU resources.");
						continue;
					}
				}

				// Step 2: Create the tonemap pipeline using the effect's bind group layout
				if (mToneMapPipeline == null && toneMap.BindGroupLayout != null)
				{
					let config = PipelineConfig.ForFullscreen("tonemap");
					if (mPipelineCache.GetOrCreate(config, toneMap.BindGroupLayout) case .Ok(let pipeline))
						mToneMapPipeline = pipeline;
				}

				// Step 3: Set the pipeline on the effect
				if (mToneMapPipeline != null)
					toneMap.Pipeline = mToneMapPipeline;
			}
		}
	}

	/// Lazily creates debug line rendering pipelines (depth-tested and overlay).
	private void EnsureDebugPipelines()
	{
		if (mDebugDepthPipeline != null)
			return;

		// Depth-tested debug line pipeline
		var depthConfig = PipelineConfig();
		depthConfig.ShaderName = "debug";
		depthConfig.VertexLayout = .DebugLine;
		depthConfig.Topology = .LineList;
		depthConfig.CullMode = .None;
		depthConfig.DepthMode = .ReadWrite;
		depthConfig.BlendMode = .Opaque;

		if (mPipelineCache.GetOrCreate(depthConfig, mEmptyBindGroupLayout, mFrameBindGroupLayout) case .Ok(let depthPl))
			mDebugDepthPipeline = depthPl;

		// Overlay (no depth test) debug line pipeline
		var noDepthConfig = PipelineConfig();
		noDepthConfig.ShaderName = "debug";
		noDepthConfig.VertexLayout = .DebugLine;
		noDepthConfig.Topology = .LineList;
		noDepthConfig.CullMode = .None;
		noDepthConfig.DepthMode = .Disabled;
		noDepthConfig.BlendMode = .Opaque;

		if (mPipelineCache.GetOrCreate(noDepthConfig, mEmptyBindGroupLayout, mFrameBindGroupLayout) case .Ok(let noDepthPl))
			mDebugNoDepthPipeline = noDepthPl;
	}

	/// Lazily creates skybox rendering resources (pipeline, bind group layout, sampler).
	private void EnsureSkyboxPipeline()
	{
		if (mSkyboxPipeline != null)
			return;

		// Create linear sampler (shared, used by skybox and potentially other features)
		if (mLinearSampler == null)
		{
			var samplerDesc = SamplerDescriptor();
			samplerDesc.MinFilter = .Linear;
			samplerDesc.MagFilter = .Linear;
			samplerDesc.MipmapFilter = .Linear;
			samplerDesc.AddressModeU = .ClampToEdge;
			samplerDesc.AddressModeV = .ClampToEdge;
			samplerDesc.AddressModeW = .ClampToEdge;
			samplerDesc.Label = "LinearSampler";
			if (mDevice.CreateSampler(&samplerDesc) case .Ok(let sampler))
				mLinearSampler = sampler;
			else
				return;
		}

		// Skybox bind group layout: cubemap texture (t0) + sampler (s0) at space0
		BindGroupLayoutEntry[2] layoutEntries = .(
			.SampledTexture(0, .Fragment),
			.Sampler(0, .Fragment)
		);
		var layoutDesc = BindGroupLayoutDescriptor(layoutEntries);
		if (mDevice.CreateBindGroupLayout(&layoutDesc) case .Ok(let layout))
			mSkyboxBindGroupLayout = layout;
		else
			return;

		// Skybox pipeline: PositionOnly, depth read-only LessEqual, front-face culling
		let config = PipelineConfig.ForSkybox("skybox");
		if (mPipelineCache.GetOrCreate(config, mSkyboxBindGroupLayout, mFrameBindGroupLayout) case .Ok(let pipeline))
			mSkyboxPipeline = pipeline;
	}

	/// Uploads per-cascade shadow view-projection data to the shadow dynamic uniform buffer.
	/// Each cascade gets its own 1024-byte-aligned slot containing a FrameUniformData struct
	/// with ViewProjection set to the light's VP matrix for that cascade.
	private void UploadShadowUniforms()
	{
		if (mShadowMap == null || mShadowFrameBuffer == null)
			return;

		let cascades = mShadowMap.Cascades;
		let count = Math.Min(cascades.Count, RenderConstants.MAX_SHADOW_CASCADES);

		for (int32 i = 0; i < count; i++)
		{
			// Build frame uniform data with the cascade's VP as ViewProjection
			var data = FrameUniformData();
			data.View = cascades[i].ViewMatrix;
			data.Projection = cascades[i].ProjectionMatrix;
			data.ViewProjection = cascades[i].ViewProjectionMatrix;

			let offset = (uint64)(i * SHADOW_FRAME_ALIGN);
			mDevice.Queue.WriteBuffer(mShadowFrameBuffer, offset,
				Span<uint8>((uint8*)&data, sizeof(FrameUniformData)));
		}
	}

	// ===== Private: Helpers =====

	/// Gets the effective dimensions for a viewport.
	private void GetViewportDimensions(Viewport viewport, out int32 width, out int32 height)
	{
		if (!viewport.Rect.IsEmpty)
		{
			width = viewport.Rect.Width;
			height = viewport.Rect.Height;
		}
		else if (viewport.RenderTarget != null)
		{
			let tex = viewport.RenderTarget.Texture;
			if (tex != null)
			{
				width = (int32)tex.Width;
				height = (int32)tex.Height;
			}
			else
			{
				width = mBackbufferWidth;
				height = mBackbufferHeight;
			}
		}
		else
		{
			// Backbuffer
			width = mBackbufferWidth;
			height = mBackbufferHeight;
		}
	}
}
