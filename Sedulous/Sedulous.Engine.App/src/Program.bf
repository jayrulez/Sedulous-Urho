using System;
using System.Collections;
using Sedulous.Engine.Core;
using Sedulous.Engine.Renderer;
using Sedulous.Engine.Physics;
using Sedulous.Engine.Physics.Jolt;
using Sedulous.Engine.Animation;
using Sedulous.Foundation.Mathematics;
using Sedulous.Geometry;
using Sedulous.Geometry.Tooling;
using Sedulous.Materials;
using Sedulous.Models;
using Sedulous.Models.GLTF;
using Sedulous.Models.FBX;
using Sedulous.Resources;
using Sedulous.Shell;
using Sedulous.Shell.Input;
using Sedulous.Imaging;
using Sedulous.Imaging.STB;
using Sedulous.Textures.Resources;
using Sedulous.Materials.Resources;
using Sedulous.RHI;
using Sedulous.Imaging.SDL;
using Sedulous.Profiler;
using Sedulous.Jobs;
using Sedulous.Engine.Navigation;
using System.Threading;

namespace Sedulous.Engine.App;

/// Port of Urho3D's 04_StaticScene sample.
/// Ground plane + 200 random objects + directional light + WASD/mouse camera.
class DemoApp : SedulousApp
{
	private Scene mScene;
	private Node mCameraNode;
	private Renderer mRenderer;
	private Viewport mViewport;
	private float mYaw = 0;
	private float mPitch = 0;

	// Physics
	private JoltPhysicsWorld mJoltWorld;
	private List<RigidBody> mDynamicBodies = new .() ~ delete _;

	// Particles (non-owning refs; scene owns the components)
	private Material mParticleMaterial;

	// Sprite
	private Material mSpriteMaterial;
	private ITexture mSpriteTexture;
	private ITextureView mSpriteTextureView;

	// Debug
	private DebugRenderer mDebugRenderer;

	// Model loading
	private List<ModelImportResult> mImportResults = new .() ~ {
		for (let r in _) delete r;
		delete _;
	};
	private List<ITexture> mModelTextures = new .() ~ {
		for (let t in _) delete t;
		delete _;
	};
	private List<ITextureView> mModelTextureViews = new .() ~ {
		for (let v in _) delete v;
		delete _;
	};

	// Async model loading
	private Monitor mModelLoadLock = new .() ~ delete _;
	private List<PendingModelLoad> mPendingModelLoads = new .() ~ {
		for (let r in _) { if (r.ImportResult != null) delete r.ImportResult; delete r; }
		delete _;
	};
	private int32 mModelsQueuedCount = 0;
	private int32 mModelsLoadedCount = 0;

	class PendingModelLoad
	{
		public String Name ~ delete _;
		public float Scale;
		public Vector3 StaticPos;
		public Vector3 AnimPos;
		public ModelImportResult ImportResult;

		public ModelImportResult TakeImportResult()
		{
			let r = ImportResult;
			ImportResult = null;
			return r;
		}
	}

	// Owned resources (not managed by scene)
	private Material mPbrMaterial;
	private List<MaterialInstance> mMaterialInstances = new .() ~ {
		for (let inst in _)
			{
				inst.ReleaseRef();
			}
		delete _;
	};
	private List<StaticMesh> mMeshes = new .() ~ {
		for (let mesh in _)
			delete mesh;
		delete _;
	};

	// Skybox
	private ITexture mSkyboxTexture;
	private ITextureView mSkyboxTextureView;

	// Ribbon trail
	private Node mTrailNode;
	private float mTrailAngle = 0;

	// Post-processing
	private PostProcessStack mPostProcessStack;
	private ToneMapEffect mToneMapEffect;

	// Additional materials for new features
	private Material mTrailMaterial;
	private Material mDecalMaterial;

	// Navigation
	private NavigationMesh mNavMesh;
	private CrowdManager mCrowdManager;
	private List<CrowdAgent> mCrowdAgents = new .() ~ delete _;
	private List<Node> mAgentNodes = new .() ~ delete _;
	private float mNavTargetTimer = 0;
	private List<Vector3> mDebugPath = new .() ~ delete _;

	protected override void Setup()
	{
		Parameters.WindowTitle = "Sedulous - Static Scene";
		Parameters.WindowWidth = 1280;
		Parameters.WindowHeight = 720;
		Parameters.PresentMode = .Immediate; // No vsync — uncapped FPS for perf testing
	}

	protected override void Start()
	{
		Logger?.LogInformation("Starting Static Scene demo...");

		// --- Initialize Profiler ---
		SProfiler.Initialize();

		// --- Initialize Renderer ---
		mRenderer = new Renderer(Logger);
		let shaderPath = scope String();
		GetAssetPath("Shaders", shaderPath);
		// Shader caching disabled — changes to .hlsli files take effect immediately
		if (mRenderer.Initialize(Device, scope StringView[](shaderPath)) case .Err)
		{
			Logger?.LogCritical("Failed to initialize renderer.");
			return;
		}
		mRenderer.SetBackbufferSize((int32)Window.Width, (int32)Window.Height);

		// --- Create Scene ---
		mScene = new Scene();
		mScene.CreateComponent<Octree>();
		mDebugRenderer = mScene.CreateComponent<DebugRenderer>();

		// --- Physics ---
		if (JoltPhysicsWorld.Create(.Default) case .Ok(let joltWorld))
		{
			mJoltWorld = joltWorld;
			let pw = mScene.CreateComponent<PhysicsWorld>();
			pw.SetWorld(joltWorld);
		}

		// --- Camera ---
		mCameraNode = mScene.CreateChild("Camera");
		mCameraNode.Position = .(0, 10, 25);
		let camera = mCameraNode.CreateComponent<Camera>();
		camera.FovDegrees = 45;
		camera.NearClip = 0.1f;
		camera.FarClip = 1000;
		camera.AutoAspectRatio = true;

		// --- Directional Light ---
		CreateLight();

		// --- Materials ---
		mPbrMaterial = Materials.CreatePBR("PBR",
			defaultAlbedo: mRenderer.MaterialSystem.WhiteTexture,
			defaultSampler: mRenderer.MaterialSystem.DefaultSampler);

		// --- Ground Plane ---
		CreateGround();

		// --- Random Objects ---
		CreateObjects(20);

		// --- Particle Effects ---
		CreateParticles();

		// --- Sprite ---
		CreateSprite();

		// --- 3D Models (static + animated, loaded asynchronously) ---
		StartModelLoading();

		// --- Point & Spot Lights ---
		CreatePointAndSpotLights();

		// --- Zone with Fog ---
		CreateZone();

		// --- Terrain ---
		//CreateTerrain();

		// --- Skybox ---
		CreateSkybox();

		// --- Procedural Geometry ---
		CreateProceduralGeometry();

		// --- Decals ---
		CreateDecals();

		// --- Ribbon Trail ---
		CreateRibbonTrail();

		// --- Navigation ---
		SetupNavigation();

		// --- Viewport ---
		mViewport = new Viewport(mScene, camera);
		mRenderer.SetViewport(0, mViewport);

		// --- Post-Processing (Tone Mapping) ---
		SetupPostProcessing();

		// --- Event Subscriptions ---
		Engine.OnUpdate.Subscribe(new => OnUpdate);
		Engine.OnRenderUpdate.Subscribe(new => OnRender);
		Engine.OnResize.Subscribe(new => OnResize);

		// Look slightly downward to see the objects
		// Negative pitch looks downward; atan(10/25) ≈ 21.8°
		mPitch = -21.8f;

		Logger?.LogInformation("Static Scene demo started. WASD to move, mouse to look, Escape to exit.");
	}

	private void CreateLight()
	{
		let lightNode = mScene.CreateChild("DirectionalLight");

		// Orient the light to shine in direction (0.6, -1.0, 0.8)
		let dir = Vector3.Normalize(.(0.6f, -1.0f, 0.8f));
		let worldMat = Matrix.CreateWorld(.Zero, dir, .Up);
		lightNode.Rotation = Quaternion.CreateFromRotationMatrix(worldMat);

		let light = lightNode.CreateComponent<Light>();
		light.LightType = .Directional;
		light.Brightness = 1.0f;
		light.CastShadowsLight = true;
	}

	private void CreateGround()
	{
		let planeNode = mScene.CreateChild("Ground");
		planeNode.Scale = .(50, 1, 50);
		planeNode.Position = .(0,0,0);

		let planeModel = planeNode.CreateComponent<StaticModel>();
		let planeMesh = StaticMesh.CreatePlane(1.0f, 1.0f, 1, 1);
		mMeshes.Add(planeMesh);
		planeModel.Mesh = planeMesh;

		if(CreateMaterialInstance(.(0.5f, 0.5f, 0.5f, 1.0f), 0.0f, 0.8f) case .Ok(let planeInst))
		{
			planeModel.SetMaterial(planeInst);
		}

		// Static physics body for the ground
		let pw = mScene.GetComponent<PhysicsWorld>();
		if (pw != null)
		{
			let shape = planeNode.CreateComponent<CollisionShape>();
			shape.ShapeType = .Box;
			shape.Size = .(25, 0.5f, 25); // Half-extents matching 50x1x50
			shape.CreateShape(pw);

			let body = planeNode.CreateComponent<RigidBody>();
			body.BodyType = .Static;
			body.CreateBody(pw);
		}
	}

	private void CreateObjects(int count)
	{
		// Pre-create shared meshes
		let cubeMesh = StaticMesh.CreateCube(1.0f);
		let sphereMesh = StaticMesh.CreateSphere(0.5f, 16, 8);
		let cylinderMesh = StaticMesh.CreateCylinder(0.5f, 1.0f, 16);
		mMeshes.Add(cubeMesh);
		mMeshes.Add(sphereMesh);
		mMeshes.Add(cylinderMesh);
		StaticMesh[3] meshes = .(cubeMesh, sphereMesh, cylinderMesh);

		// Pre-create colored materials
		MaterialInstance[4] materials = .(
			CreateMaterialInstance(.(0.8f, 0.2f, 0.2f, 1.0f), 0.0f, 0.4f),  // Red
			CreateMaterialInstance(.(0.2f, 0.8f, 0.2f, 1.0f), 0.0f, 0.5f),  // Green
			CreateMaterialInstance(.(0.2f, 0.2f, 0.8f, 1.0f), 0.0f, 0.3f),  // Blue
			CreateMaterialInstance(.(0.8f, 0.8f, 0.2f, 1.0f), 0.2f, 0.6f)   // Yellow metallic
		);

		let pw = mScene.GetComponent<PhysicsWorld>();
		let rng = scope Random();

		for (int i = 0; i < count; i++)
		{
			let node = mScene.CreateChild("Object");
			let scale = 0.5f + (float)rng.NextDouble() * 2.0f;
			// Start elevated so objects fall under gravity (stay within ground bounds)
			node.Position = .((float)rng.NextDouble() * 40.0f - 20.0f,
				1.0f + (float)rng.NextDouble() * 14.0f,
				(float)rng.NextDouble() * 40.0f - 20.0f);
			node.Rotation = Quaternion.CreateFromYawPitchRoll((float)rng.NextDouble() * Math.PI_f * 2.0f, 0, 0);
			node.Scale = .(scale, scale, scale);

			let meshIdx = rng.Next(3);
			let model = node.CreateComponent<StaticModel>();
			model.Mesh = meshes[meshIdx];
			model.SetMaterial(materials[rng.Next(4)]);
			model.CastShadows = true;

			// Add physics body
			if (pw != null)
			{
				let shape = node.CreateComponent<CollisionShape>();
				switch (meshIdx)
				{
				case 0: // Cube
					shape.ShapeType = .Box;
					shape.Size = .(0.5f * scale, 0.5f * scale, 0.5f * scale);
				case 1: // Sphere
					shape.ShapeType = .Sphere;
					shape.Radius = 0.5f * scale;
				case 2: // Cylinder
					shape.ShapeType = .Cylinder;
					shape.HalfHeight = 0.5f * scale;
					shape.Radius = 0.5f * scale;
				}
				shape.CreateShape(pw);

				let body = node.CreateComponent<RigidBody>();
				body.Mass = 1.0f;
				body.Restitution = 0.3f;
				body.CreateBody(pw);
				mDynamicBodies.Add(body);
			}
		}
	}

	private void CreateParticles()
	{
		// Create a shared additive particle material using the billboard shader.
		// WhiteTexture means color comes entirely from vertex colors.
		mParticleMaterial = scope MaterialBuilder("ParticleMat")
			.Shader("billboard")
			.VertexLayout(.PositionUVColor)
			.Additive()
			.Cull(.None)
			.Texture("AlbedoMap", mRenderer.MaterialSystem.WhiteTexture)
			.Sampler("MainSampler", mRenderer.MaterialSystem.DefaultSampler)
			.Build();

		// --- Fire emitter (center) ---
		{
			let node = mScene.CreateChild("Fire");
			node.Position = .(0, 0.5f, 0);
			let emitter = node.CreateComponent<ParticleEmitter>();
			emitter.EmissionRate = 100;
			emitter.MaxParticles = 400;
			emitter.MinLifetime = 0.5f;
			emitter.MaxLifetime = 1.5f;
			emitter.MinSpeed = 2.0f;
			emitter.MaxSpeed = 6.0f;
			emitter.MinSize = 0.6f;
			emitter.MaxSize = 1.5f;
			emitter.EndSizeScale = 0.0f;
			emitter.EmissionDirection = .(0, 1, 0);
			emitter.DirectionSpread = Math.PI_f / 4.0f;
			emitter.Gravity = .Zero;
			emitter.StartColor = BillboardSet.PackColor(1.0f, 0.9f, 0.3f, 1.0f);
			emitter.EndColor = BillboardSet.PackColor(1.0f, 0.1f, 0.0f, 0.0f);
			emitter.MinRotationSpeed = -2.0f;
			emitter.MaxRotationSpeed = 2.0f;

			let inst = new MaterialInstance(mParticleMaterial);
			mMaterialInstances.Add(inst);
			if (mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
				emitter.Material = inst;
			emitter.Start();
		}

		// --- Fountain emitter (left-back) ---
		{
			let node = mScene.CreateChild("Fountain");
			node.Position = .(-8, 0.5f, -8);
			let emitter = node.CreateComponent<ParticleEmitter>();
			emitter.EmissionRate = 40;
			emitter.MaxParticles = 200;
			emitter.MinLifetime = 1.0f;
			emitter.MaxLifetime = 3.0f;
			emitter.MinSpeed = 8.0f;
			emitter.MaxSpeed = 15.0f;
			emitter.MinSize = 0.1f;
			emitter.MaxSize = 0.3f;
			emitter.EndSizeScale = 0.5f;
			emitter.EmissionDirection = .(0, 1, 0);
			emitter.DirectionSpread = Math.PI_f / 6.0f;
			emitter.Gravity = .(0, -9.81f, 0);
			emitter.StartColor = BillboardSet.PackColor(0.2f, 0.8f, 1.0f, 1.0f);
			emitter.EndColor = BillboardSet.PackColor(0.1f, 0.3f, 1.0f, 0.0f);

			let inst = new MaterialInstance(mParticleMaterial);
			mMaterialInstances.Add(inst);
			if (mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
				emitter.Material = inst;
			emitter.Start();
		}

		// --- Spark emitter (right-back) ---
		{
			let node = mScene.CreateChild("Sparks");
			node.Position = .(8, 0.5f, 8);
			let emitter = node.CreateComponent<ParticleEmitter>();
			emitter.EmissionRate = 60;
			emitter.MaxParticles = 150;
			emitter.MinLifetime = 0.3f;
			emitter.MaxLifetime = 1.0f;
			emitter.MinSpeed = 5.0f;
			emitter.MaxSpeed = 12.0f;
			emitter.MinSize = 0.05f;
			emitter.MaxSize = 0.15f;
			emitter.EndSizeScale = 0.0f;
			emitter.EmissionDirection = .(0, 1, 0);
			emitter.DirectionSpread = Math.PI_f / 2.0f;
			emitter.Gravity = .(0, -5.0f, 0);
			emitter.StartColor = BillboardSet.PackColor(1.0f, 1.0f, 1.0f, 1.0f);
			emitter.EndColor = BillboardSet.PackColor(1.0f, 0.5f, 0.1f, 0.0f);
			emitter.MinRotationSpeed = -5.0f;
			emitter.MaxRotationSpeed = 5.0f;

			let inst = new MaterialInstance(mParticleMaterial);
			mMaterialInstances.Add(inst);
			if (mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
				emitter.Material = inst;
			emitter.Start();
		}
	}

	private void CreateSprite()
	{
		// Generate a checkerboard texture procedurally
		let image = Image.CreateCheckerboard(128, Color(1.0f, 0.3f, 0.8f, 1.0f), Color(0.2f, 0.1f, 0.5f, 1.0f), 16);
		defer delete image;

		// Upload to GPU
		var texDesc = TextureDescriptor.Texture2D(128, 128, .RGBA8Unorm, .Sampled | .CopyDst);
		if (Device.CreateTexture(&texDesc) case .Ok(let tex))
			mSpriteTexture = tex;
		else
			return;

		var layout = TextureDataLayout() { Offset = 0, BytesPerRow = 128 * 4, RowsPerImage = 128 };
		var writeSize = Extent3D() { Width = 128, Height = 128, Depth = 1 };
		Device.Queue.WriteTexture(mSpriteTexture, image.Data, &layout, &writeSize);

		var viewDesc = TextureViewDescriptor() { Format = .RGBA8Unorm };
		if (Device.CreateTextureView(mSpriteTexture, &viewDesc) case .Ok(let view))
			mSpriteTextureView = view;
		else
			return;

		// Create sprite material
		mSpriteMaterial = Materials.CreateSprite("SpriteMat",
			texture: mSpriteTextureView,
			sampler: mRenderer.MaterialSystem.DefaultSampler);

		// Create sprite node and component
		let spriteNode = mScene.CreateChild("Sprite");
		spriteNode.Position = .(0, 3, 0);
		let sprite = spriteNode.CreateComponent<Sprite2D>();
		sprite.Size = .(3.0f, 3.0f);
		sprite.DrawMode = .World;

		let spriteInst = new MaterialInstance(mSpriteMaterial);
		mMaterialInstances.Add(spriteInst);
		if (mRenderer.MaterialSystem.PrepareInstance(spriteInst) case .Ok)
			sprite.Material = spriteInst;
	}

		struct ModelDef
		{
			public StringView path;
			public StringView name;
			public float scale;
			public Vector3 staticPos;
			public Vector3 animPos;
		}

	private void StartModelLoading()
	{
		// Initialize model loaders and image decoder (must be on main thread)
		SDLImageLoader.Initialize();
		STBImageLoader.Initialize();
		GltfModels.Initialize();
		FbxModels.Initialize();

		ModelDef[?] models = .(
			.() { path = "Models/PlatformerGameKit/Character/glTF/Character.gltf", name = "CharGLTF", scale = 1.0f, staticPos = .(-10, 0, 10), animPos = .(-7, 0, 10) },
			.() { path = "Models/PlatformerGameKit/Character/FBX/Character.fbx", name = "CharFBX", scale = 1.0f, staticPos = .(-4, 0, 10), animPos = .(-1, 0, 10) },
			.() { path = "Models/Fox/glTF/Fox.gltf", name = "Fox", scale = 0.03f, staticPos = .(2, 0, 10), animPos = .(5, 0, 10) },
			.() { path = "Models/UltimateMonsters/Blob/glTF/GreenBlob.gltf", name = "GreenBlob", scale = 1.0f, staticPos = .(8, 0, 10), animPos = .(11, 0, 10) }
		);

		let jobSystem = Context.GetSubsystem<JobSystem>();

		for (let def in models)
		{
			// Pre-compute paths on main thread (GetAssetPath uses app state)
			let fullPath = new String();
			GetAssetPath(def.path, fullPath);

			let basePath = new String(fullPath);
			let lastSlash = Math.Max(basePath.LastIndexOf('/'), basePath.LastIndexOf('\\'));
			if (lastSlash >= 0)
				basePath.RemoveToEnd(lastSlash + 1);

			let name = new String(def.name);
			let scale = def.scale;
			let staticPos = def.staticPos;
			let animPos = def.animPos;

			mModelsQueuedCount++;

			if (jobSystem != null && jobSystem.IsRunning)
			{
				// Background job: disk I/O + model parsing + image conversion
				jobSystem.AddJob(
					new () => {
						LoadSingleModel(fullPath, basePath, name, scale, staticPos, animPos);
					},
					ownsJobDelegate: true,
					jobName: def.name
				);
			}
			else
			{
				// Fallback: synchronous loading
				LoadSingleModel(fullPath, basePath, name, scale, staticPos, animPos);
			}
		}
	}

	/// Loads a single model on the background thread and queues it for main-thread processing.
	/// Takes ownership of fullPath, basePath, and name strings.
	private void LoadSingleModel(String fullPath, String basePath, String name, float scale, Vector3 staticPos, Vector3 animPos)
	{
		defer { delete fullPath; delete basePath; }

		let model = new Sedulous.Models.Model();
		defer delete model;

		let loadResult = ModelLoaderFactory.LoadModel(fullPath, model);
		if (loadResult != .Ok)
		{
			Logger?.LogWarning(scope $"Failed to load model '{name}': {loadResult}");
			delete name;
			return;
		}

		let options = new ModelImportOptions();
		options.Flags = .All;
		options.BasePath.Set(basePath);

		let importer = new ModelImporter(options);
		defer delete importer;
		let result = importer.Import(model);

		if (!result.Success)
		{
			for (let err in result.Errors)
				Logger?.LogWarning(scope $"Import error for '{name}': {err}");
			delete result;
			delete name;
			return;
		}

		for (let warn in result.Warnings)
			Logger?.LogInformation(scope $"Import warning for '{name}': {warn}");

		Logger?.LogInformation(scope $"Imported '{name}': {result.StaticMeshes.Count} static, {result.SkinnedMeshes.Count} skinned, {result.Skeletons.Count} skeletons, {result.Animations.Count} anims, {result.Textures.Count} textures, {result.Materials.Count} materials");

		// Queue for main-thread processing (GPU upload + scene creation)
		let pending = new PendingModelLoad();
		pending.Name = name; // transfer ownership
		pending.Scale = scale;
		pending.StaticPos = staticPos;
		pending.AnimPos = animPos;
		pending.ImportResult = result;

		using (mModelLoadLock.Enter())
			mPendingModelLoads.Add(pending);
	}

	/// Processes models that finished loading on background threads.
	/// Uploads textures, creates materials, and adds scene nodes on the main thread.
	private void ProcessPendingModels()
	{
		let toProcess = scope List<PendingModelLoad>();

		using (mModelLoadLock.Enter())
		{
			if (mPendingModelLoads.Count == 0)
				return;
			toProcess.AddRange(mPendingModelLoads);
			mPendingModelLoads.Clear();
		}

		for (let pending in toProcess)
		{
			let result = pending.ImportResult;

			// Upload textures to GPU
			let textureMap = scope Dictionary<Guid, ITextureView>();
			UploadModelTextures(result, textureMap);

			// Create material instances from imported materials
			let materials = CreateModelMaterials(result, textureMap);
			defer delete materials;

			// Create scene nodes (static + animated)
			CreateModelPair(pending.Name, pending.StaticPos, pending.AnimPos, pending.Scale, result, materials);

			// Transfer import result ownership to mImportResults
			mImportResults.Add(pending.TakeImportResult());

			mModelsLoadedCount++;
			Logger?.LogInformation(scope $"Model '{pending.Name}' added to scene ({mModelsLoadedCount}/{mModelsQueuedCount})");

			delete pending;
		}
	}

	private void UploadModelTextures(ModelImportResult result, Dictionary<Guid, ITextureView> textureMap)
	{
		for (let texRes in result.Textures)
		{
			let image = texRes.Image;
			if (image == null) continue;

			// Convert non-RGBA8 images to RGBA8 for GPU upload
			Image uploadImage = image;
			Image convertedImage = null;
			if (image.Format != .RGBA8 && image.Format != .BGRA8)
			{
				if (image.ConvertFormat(.RGBA8) case .Ok(let converted))
				{
					convertedImage = converted;
					uploadImage = converted;
				}
				else
					continue;
			}

			let format = uploadImage.Format == .BGRA8 ? TextureFormat.BGRA8Unorm : TextureFormat.RGBA8Unorm;
			var texDesc = TextureDescriptor.Texture2D(uploadImage.Width, uploadImage.Height, format, .Sampled | .CopyDst);

			ITexture gpuTex = null;
			if (Device.CreateTexture(&texDesc) case .Ok(let tex))
				gpuTex = tex;
			else
			{
				if (convertedImage != null) delete convertedImage;
				continue;
			}

			var layout = TextureDataLayout() { Offset = 0, BytesPerRow = uploadImage.Width * 4, RowsPerImage = uploadImage.Height };
			var writeSize = Extent3D() { Width = uploadImage.Width, Height = uploadImage.Height, Depth = 1 };
			Device.Queue.WriteTexture(gpuTex, uploadImage.Data, &layout, &writeSize);

			var viewDesc = TextureViewDescriptor() { Format = format };
			if (Device.CreateTextureView(gpuTex, &viewDesc) case .Ok(let view))
			{
				mModelTextures.Add(gpuTex);
				mModelTextureViews.Add(view);
				textureMap[texRes.Id] = view;
			}
			else
			{
				delete gpuTex;
			}

			if (convertedImage != null) delete convertedImage;
		}
	}

	private List<MaterialInstance> CreateModelMaterials(ModelImportResult result, Dictionary<Guid, ITextureView> textureMap)
	{
		let materials = new List<MaterialInstance>();

		for (let matRes in result.Materials)
		{
			let mat = matRes.Material;
			if (mat == null)
			{
				materials.Add(null);
				continue;
			}

			// Set default textures/samplers on the material so bind group creation succeeds
			mat.SetDefaultTexture("AlbedoMap", mRenderer.MaterialSystem.WhiteTexture);
			mat.SetDefaultTexture("NormalMap", mRenderer.MaterialSystem.WhiteTexture);
			mat.SetDefaultTexture("MetallicRoughnessMap", mRenderer.MaterialSystem.WhiteTexture);
			mat.SetDefaultTexture("OcclusionMap", mRenderer.MaterialSystem.WhiteTexture);
			mat.SetDefaultTexture("EmissiveMap", mRenderer.MaterialSystem.WhiteTexture);
			mat.SetDefaultSampler("MainSampler", mRenderer.MaterialSystem.DefaultSampler);

			// Create instance
			let inst = new MaterialInstance(mat);

			// Override textures from imported texture refs
			for (let kv in matRes.TextureRefs)
			{
				let slotName = kv.key;
				let texRef = kv.value;
				if (texRef.HasId && textureMap.TryGetValue(texRef.Id, let view))
				{
					inst.SetTexture(slotName, view);
				}
			}

			mMaterialInstances.Add(inst);
			if (mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
				materials.Add(inst);
			else
			{
				Logger?.LogWarning(scope $"Failed to prepare material instance");
				materials.Add(null);
			}
		}

		return materials;
	}

	private void CreateModelPair(StringView name, Vector3 staticPos, Vector3 animPos, float scale, ModelImportResult result, List<MaterialInstance> materials)
	{
		// --- Static version (use importer's StaticMeshes which have node transforms baked in) ---
		if (result.StaticMeshes.Count > 0 && result.StaticMeshes[0].Mesh != null)
		{
			let srcMesh = result.StaticMeshes[0].Mesh;
			let node = mScene.CreateChild(scope $"{name}_Static");
			node.Position = staticPos;
			node.Scale = .(scale, scale, scale);

			let model = node.CreateComponent<StaticModel>();
			model.Mesh = srcMesh;
			model.CastShadows = true;

			for (int i = 0; i < srcMesh.SubMeshes.Count; i++)
			{
				let matIdx = srcMesh.SubMeshes[i].materialIndex;
				if (matIdx >= 0 && matIdx < materials.Count && materials[matIdx] != null)
					model.SetMaterial(i, materials[matIdx]);
			}
			Logger?.LogInformation(scope $"Created static model '{name}' from static mesh ({srcMesh.Vertices.VertexCount} verts, {srcMesh.SubMeshes.Count} submeshes)");
		}
		else
		{
			Logger?.LogWarning(scope $"No static meshes in '{name}', skipping static version");
		}

		// --- Animated version (testing with 1 model) ---
		if (result.SkinnedMeshes.Count > 0 && result.SkinnedMeshes[0].Mesh != null)
		{
			let skinnedMesh = result.SkinnedMeshes[0].Mesh;
			let node = mScene.CreateChild(scope $"{name}_Anim");
			node.Position = animPos;
			node.Scale = .(scale, scale, scale);

			let animModel = node.CreateComponent<AnimatedModel>();
			animModel.SkinnedMesh = skinnedMesh;
			animModel.CastShadows = true;

			if (result.Skeletons.Count > 0)
				animModel.Skeleton = result.Skeletons[0].Skeleton;

			if (result.Animations.Count > 0)
			{
				let clip = result.Animations[0].Clip;
				if (clip != null)
				{
					clip.IsLooping = true;
					animModel.PlayAnimation(clip);
				}
			}

			for (int i = 0; i < skinnedMesh.SubMeshes.Count; i++)
			{
				let matIdx = skinnedMesh.SubMeshes[i].materialIndex;
				if (matIdx >= 0 && matIdx < materials.Count && materials[matIdx] != null)
					animModel.SetMaterial(i, materials[matIdx]);
			}

			Logger?.LogInformation(scope $"Created animated model '{name}' ({skinnedMesh.VertexCount} verts, {skinnedMesh.SubMeshes.Count} submeshes, {result.Animations.Count} anims)");
		}
	}


	private Result<MaterialInstance> CreateMaterialInstance(Vector4 baseColor, float metallic, float roughness)
	{
		let inst = new MaterialInstance(mPbrMaterial);
		inst.SetColor("BaseColor", baseColor);
		inst.SetFloat("Metallic", metallic);
		inst.SetFloat("Roughness", roughness);
		mMaterialInstances.Add(inst);
		if(mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
			return inst;
		return .Err;
	}

	// =====================================================================
	// New Feature Methods (uncomment calls in Start() one at a time)
	// =====================================================================

	private void CreatePointAndSpotLights()
	{
		// Blue-ish point light
		{
			let node = mScene.CreateChild("PointLight");
			node.Position = .(5, 4, 5);
			let light = node.CreateComponent<Light>();
			light.LightType = .Point;
			light.LightColor = Color(0.4f, 0.6f, 1.0f, 1.0f);
			light.Brightness = 2.0f;
			light.Range = 15.0f;
		}

		// Yellow spot light aimed downward
		{
			let node = mScene.CreateChild("SpotLight");
			node.Position = .(-5, 8, 0);
			let dir = Vector3.Normalize(.(0.0f, -1.0f, 0.2f));
			let worldMat = Matrix.CreateWorld(.Zero, dir, .Up);
			node.Rotation = Quaternion.CreateFromRotationMatrix(worldMat);

			let light = node.CreateComponent<Light>();
			light.LightType = .Spot;
			light.LightColor = Color(1.0f, 0.9f, 0.5f, 1.0f);
			light.Brightness = 2.0f;
			light.Range = 20.0f;
			light.SpotFov = 60.0f * (Math.PI_f / 180.0f);
			light.CastShadowsLight = true;
		}
	}

	private void CreateZone()
	{
		let zoneNode = mScene.CreateChild("Zone");
		let zone = zoneNode.CreateComponent<Zone>();
		zone.AmbientColor = Color(0.25f, 0.25f, 0.3f, 1.0f);
		zone.FogColor = Color(0.5f, 0.6f, 0.7f, 1.0f);
		zone.FogStart = 40.0f;
		zone.FogEnd = 120.0f;
	}

	private Material mTerrainMat ~ delete _;

	private void CreateTerrain()
	{
		let terrainNode = mScene.CreateChild("Terrain");
		terrainNode.Position = .(-30, -1, -30);

		let terrain = terrainNode.CreateComponent<Terrain>();
		terrain.Spacing = .(1.0f, 5.0f, 1.0f);

		// Generate procedural heightmap (65x65)
		int32 mapSize = 65;
		let heights = new float[mapSize * mapSize];
		defer delete heights;

		for (int32 z = 0; z < mapSize; z++)
		{
			for (int32 x = 0; x < mapSize; x++)
			{
				float fx = (float)x / (float)mapSize;
				float fz = (float)z / (float)mapSize;
				// Rolling hills using sine waves
				float h = 0.0f;
				h += Math.Sin(fx * Math.PI_f * 2.0f) * 0.3f;
				h += Math.Sin(fz * Math.PI_f * 3.0f) * 0.2f;
				h += Math.Sin((fx + fz) * Math.PI_f * 4.0f) * 0.1f;
				h = h * 0.5f + 0.5f; // Normalize to [0, 1]
				heights[z * mapSize + x] = h;
			}
		}

		terrain.SetHeightMap(Span<float>(&heights[0], mapSize * mapSize), mapSize, mapSize);

		// Green-brown ground material — terrain uses MeshNoTangent (32 bytes: Pos+Normal+UV)
		mTerrainMat = scope MaterialBuilder("TerrainMat")
			.Shader("terrain")
			.VertexLayout(.MeshNoTangent)
			.Color("BaseColor", .(1, 1, 1, 1))
			.Float("Metallic", 0.0f)
			.Float("Roughness", 0.5f)
			.Float("AO", 1.0f)
			.Float("AlphaCutoff", 0.0f)
			.Color("EmissiveColor", .(0, 0, 0, 0))
			.Texture("AlbedoMap", mRenderer.MaterialSystem.WhiteTexture)
			.Texture("NormalMap", mRenderer.MaterialSystem.WhiteTexture)
			.Texture("MetallicRoughnessMap", mRenderer.MaterialSystem.WhiteTexture)
			.Texture("OcclusionMap", mRenderer.MaterialSystem.WhiteTexture)
			.Texture("EmissiveMap", mRenderer.MaterialSystem.WhiteTexture)
			.Sampler("MainSampler", mRenderer.MaterialSystem.DefaultSampler)
			.Build();

		let terrainInst = new MaterialInstance(mTerrainMat);
		terrainInst.SetColor("BaseColor", .(0.3f, 0.45f, 0.2f, 1.0f));
		terrainInst.SetFloat("Roughness", 0.9f);
		mMaterialInstances.Add(terrainInst);
		if (mRenderer.MaterialSystem.PrepareInstance(terrainInst) case .Ok)
			terrain.Material = terrainInst;
	}

	private void CreateSkybox()
	{
		int32 faceSize = 64;
		int32 faceBytes = faceSize * faceSize * 4;

		// Create cubemap texture (2D array with 6 layers)
		var texDesc = TextureDescriptor.Texture2D((uint32)faceSize, (uint32)faceSize, .RGBA8Unorm, .Sampled | .CopyDst);
		texDesc.ArrayLayerCount = 6;

		if (Device.CreateTexture(&texDesc) case .Ok(let tex))
			mSkyboxTexture = tex;
		else
			return;

		// Generate gradient data and upload each face
		let faceData = new uint8[faceBytes];
		defer delete faceData;

		for (int32 face = 0; face < 6; face++)
		{
			for (int32 y = 0; y < faceSize; y++)
			{
				float t = (float)y / (float)(faceSize - 1);
				uint8 r, g, b;

				if (face == 2) // +Y (top) — sky blue
				{
					r = (uint8)(60 + (1.0f - t) * 40);
					g = (uint8)(120 + (1.0f - t) * 40);
					b = (uint8)(200 + (1.0f - t) * 40);
				}
				else if (face == 3) // -Y (bottom) — dark ground
				{
					r = 40; g = 35; b = 30;
				}
				else // Side faces — gradient from blue (top) to light horizon (bottom)
				{
					r = (uint8)(100 + t * 80);
					g = (uint8)(140 + t * 50);
					b = (uint8)(210 - t * 20);
				}

				for (int32 x = 0; x < faceSize; x++)
				{
					let idx = (y * faceSize + x) * 4;
					faceData[idx + 0] = r;
					faceData[idx + 1] = g;
					faceData[idx + 2] = b;
					faceData[idx + 3] = 255;
				}
			}

			// Upload this face to the appropriate array layer
			var layout = TextureDataLayout() { Offset = 0, BytesPerRow = (uint32)(faceSize * 4), RowsPerImage = (uint32)faceSize };
			var writeSize = Extent3D() { Width = (uint32)faceSize, Height = (uint32)faceSize, Depth = 1 };
			Device.Queue.WriteTexture(mSkyboxTexture, Span<uint8>(&faceData[0], faceBytes), &layout, &writeSize, 0, (uint32)face);
		}

		// Create cubemap view
		var viewDesc = TextureViewDescriptor() { Format = .RGBA8Unorm, Dimension = .TextureCube, ArrayLayerCount = 6 };
		if (Device.CreateTextureView(mSkyboxTexture, &viewDesc) case .Ok(let view))
			mSkyboxTextureView = view;
		else
			return;

		// Create skybox node and component
		let skyNode = mScene.CreateChild("Skybox");
		let skybox = skyNode.CreateComponent<Skybox>();
		skybox.CubemapView = mSkyboxTextureView;
		skybox.CreateBuffers(Device);
	}

	private void CreateProceduralGeometry()
	{
		let node = mScene.CreateChild("Pyramid");
		node.Position = .(12, 1, 0);

		let proc = node.CreateComponent<ProceduralGeometry>();
		proc.CastShadows = true;
		proc.BeginGeometry();

		// Build a pyramid: square base + 4 triangular faces
		float s = 1.5f; // Half-size of base
		float h = 3.0f; // Height

		Vector3 bl = .(-s, 0, -s); // Base corners
		Vector3 br = .(s, 0, -s);
		Vector3 fr = .(s, 0, s);
		Vector3 fl = .(-s, 0, s);
		Vector3 top = .(0, h, 0);

		uint32 gold = 0xFF00D4FF; // ABGR: golden yellow

		// Base quad (two triangles, facing down)
		proc.AddQuad(bl, br, fr, fl, gold);

		// Front face
		proc.AddTriangle(fl, fr, top, gold);
		// Right face
		proc.AddTriangle(fr, br, top, gold);
		// Back face
		proc.AddTriangle(br, bl, top, gold);
		// Left face
		proc.AddTriangle(bl, fl, top, gold);

		proc.Commit();

		// ProceduralVertex now matches the standard Mesh layout (48 bytes) — use normal PBR material
		if (CreateMaterialInstance(.(0.9f, 0.7f, 0.2f, 1.0f), 0.3f, 0.4f) case .Ok(let inst))
			proc.DefaultMaterial = inst;
	}

	private void CreateDecals()
	{
		let node = mScene.CreateChild("Decals");
		let decalSet = node.CreateComponent<DecalSet>();

		// Create a decal material — Decal vertex layout (36 bytes: Pos+Normal+UV+Color)
		// Must declare all uniforms that decal.frag.hlsl expects in MaterialUniforms cbuffer
		mDecalMaterial = scope MaterialBuilder("DecalMat")
			.Shader("decal")
			.VertexLayout(.Decal)
			.Transparent()
			.Cull(.None)
			.Color("BaseColor", .(1, 1, 1, 1))
			.Float("Metallic", 0.0f)
			.Float("Roughness", 0.5f)
			.Float("AO", 1.0f)
			.Float("AlphaCutoff", 0.0f)
			.Color("EmissiveColor", .(0, 0, 0, 0))
			.Texture("AlbedoMap", mRenderer.MaterialSystem.WhiteTexture)
			.Sampler("MainSampler", mRenderer.MaterialSystem.DefaultSampler)
			.Build();

		let inst = new MaterialInstance(mDecalMaterial);
		inst.SetColor("BaseColor", .(0.8f, 0.2f, 0.2f, 0.7f));
		mMaterialInstances.Add(inst);
		if (mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
			decalSet.Material = inst;

		// Scatter a few decals on the ground
		decalSet.AddDecal(.(0, 0.01f, 5), .(0, 1, 0), 2.0f);
		decalSet.AddDecal(.(4, 0.01f, -3), .(0, 1, 0), 1.5f);
		decalSet.AddDecal(.(-3, 0.01f, -6), .(0, 1, 0), 2.5f);
		decalSet.AddDecal(.(6, 0.01f, 2), .(0, 1, 0), 1.8f);
	}

	private void CreateRibbonTrail()
	{
		// Create an orbiting node
		mTrailNode = mScene.CreateChild("TrailOrbit");
		mTrailNode.Position = .(6, 3, 0);

		let trail = mTrailNode.CreateComponent<RibbonTrail>();
		trail.Width = 0.5f;
		trail.EndWidth = 0.0f;
		trail.Lifetime = 1.5f;
		trail.MinVertexDistance = 0.3f;
		trail.MaxPoints = 50;
		trail.StartColor = BillboardSet.PackColor(0.2f, 0.8f, 1.0f, 1.0f);
		trail.EndColor = BillboardSet.PackColor(0.1f, 0.3f, 1.0f, 0.0f);
		trail.Emitting = true;

		// Create additive trail material using billboard shader
		mTrailMaterial = scope MaterialBuilder("TrailMat")
			.Shader("billboard")
			.VertexLayout(.PositionUVColor)
			.Additive()
			.Cull(.None)
			.Texture("AlbedoMap", mRenderer.MaterialSystem.WhiteTexture)
			.Sampler("MainSampler", mRenderer.MaterialSystem.DefaultSampler)
			.Build();

		let inst = new MaterialInstance(mTrailMaterial);
		mMaterialInstances.Add(inst);
		if (mRenderer.MaterialSystem.PrepareInstance(inst) case .Ok)
			trail.Material = inst;
	}

	private void UpdateTrailOrbit(float timeStep)
	{
		if (mTrailNode == null) return;
		mTrailAngle += timeStep * 2.0f; // ~2 rad/sec
		float radius = 6.0f;
		mTrailNode.Position = .(
			Math.Cos(mTrailAngle) * radius,
			3.0f + Math.Sin(mTrailAngle * 0.7f) * 1.0f, // Gentle vertical bob
			Math.Sin(mTrailAngle) * radius
		);
	}

	private void SetupPostProcessing()
	{
		mPostProcessStack = new PostProcessStack();
		mToneMapEffect = new ToneMapEffect();
		mToneMapEffect.Method = .ACES;
		mToneMapEffect.Exposure = 1.0f;
		mToneMapEffect.Gamma = 2.2f;
		// NOTE: ToneMapEffect may need InitializeGPU() with a pipeline — verify when enabling
		mPostProcessStack.AddEffect(mToneMapEffect);
		mViewport.PostProcessStack = mPostProcessStack;
	}

	private void SetupNavigation()
	{
		// Build navmesh from the ground plane (50x50 flat quad at Y=0)
		let navNode = mScene.CreateChild("Navigation");
		mNavMesh = navNode.CreateComponent<NavigationMesh>();
		mNavMesh.CellSize = 0.3f;
		mNavMesh.CellHeight = 0.2f;
		mNavMesh.AgentHeight = 1.8f;
		mNavMesh.AgentRadius = 0.5f;

		// Ground plane triangle soup: two triangles covering -25..25 on XZ at Y=0
		float halfSize = 25.0f;
		float[12] verts = .(
			-halfSize, 0, -halfSize,
			 halfSize, 0, -halfSize,
			 halfSize, 0,  halfSize,
			-halfSize, 0,  halfSize
		);
		int32[6] indices = .(0, 2, 1, 0, 3, 2);
		let bounds = BoundingBox(.(-halfSize, -0.5f, -halfSize), .(halfSize, 0.5f, halfSize));

		if (mNavMesh.Build(Span<float>(&verts[0], 12), Span<int32>(&indices[0], 6), bounds) case .Err)
		{
			Console.WriteLine("[Nav] Failed to build navigation mesh");
			return;
		}
		Console.WriteLine("[Nav] Navigation mesh built successfully");

		// Initialize crowd manager
		mCrowdManager = navNode.CreateComponent<CrowdManager>();
		mCrowdManager.MaxAgents = 32;
		if (mCrowdManager.Initialize(mNavMesh) case .Err)
		{
			Console.WriteLine("[Nav] Failed to initialize crowd manager");
			return;
		}
		Console.WriteLine("[Nav] Crowd manager initialized");

		// Create agent nodes — small colored boxes that navigate the ground
		Color[4] agentColors = .(
			Color(1.0f, 0.3f, 0.3f, 1.0f),
			Color(0.3f, 1.0f, 0.3f, 1.0f),
			Color(0.3f, 0.3f, 1.0f, 1.0f),
			Color(1.0f, 1.0f, 0.3f, 1.0f)
		);
		Vector3[4] startPositions = .(
			.(-8, 0.5f, -8),
			.( 8, 0.5f, -8),
			.( 8, 0.5f,  8),
			.(-8, 0.5f,  8)
		);

		for (int i = 0; i < 4; i++)
		{
			let agentNode = mScene.CreateChild("NavAgent");
			agentNode.Position = startPositions[i];
			agentNode.Scale = .(0.6f, 1.0f, 0.6f);

			// Visual: small box
			let model = agentNode.CreateComponent<StaticModel>();
			let mesh = StaticMesh.CreateCube(1.0f);
			mMeshes.Add(mesh);
			model.Mesh = mesh;
			let col = agentColors[i];
			if (CreateMaterialInstance(.((float)col.R / 255.0f, (float)col.G / 255.0f, (float)col.B / 255.0f, 1.0f), 0.0f, 0.5f) case .Ok(let inst))
				model.SetMaterial(inst);

			// Navigation agent
			let agent = agentNode.CreateComponent<CrowdAgent>();
			agent.Radius = 0.5f;
			agent.Height = 1.0f;
			agent.MaxSpeed = 3.5f;
			agent.MaxAcceleration = 8.0f;
			if (agent.Register(mCrowdManager) case .Ok)
			{
				mCrowdAgents.Add(agent);
				mAgentNodes.Add(agentNode);
			}
		}

		Console.WriteLine(scope $"[Nav] {mCrowdAgents.Count} agents registered");
	}

	private void UpdateNavigation(float timeStep)
	{
		if (mCrowdManager == null || !mCrowdManager.IsInitialized)
			return;

		// Periodically assign random targets
		mNavTargetTimer -= timeStep;
		if (mNavTargetTimer <= 0)
		{
			mNavTargetTimer = 4.0f; // New targets every 4 seconds
			for (int ai = 0; ai < mCrowdAgents.Count; ai++)
			{
				let agent = mCrowdAgents[ai];
				if (mNavMesh.GetRandomPoint() case .Ok(let target))
				{
					agent.SetTargetPosition(target);

					// Store first agent's path for debug drawing
					if (ai == 0)
					{
						mDebugPath.Clear();
						mNavMesh.FindPath(agent.CrowdPosition, target, mDebugPath);
					}
				}
			}
		}

		// Step crowd simulation
		mCrowdManager.Update(timeStep);

		// Sync node positions from crowd
		for (let agent in mCrowdAgents)
		{
			agent.SyncFromCrowd();
			// Keep agents at visual height (crowd operates on navmesh Y=0)
			if (agent.Node != null)
			{
				var pos = agent.Node.Position;
				pos.Y = 0.5f;
				agent.Node.Position = pos;
			}
		}
	}

	private void OnUpdate(float timeStep)
	{
		using (SProfiler.Begin("App.OnUpdate"))
		{
		// Process models that finished loading on background threads
		ProcessPendingModels();

		// --- Update Ribbon Trail orbit ---
		UpdateTrailOrbit(timeStep);

		// --- Update Navigation ---
		UpdateNavigation(timeStep);

		// Step physics and sync dynamic body transforms
		using (SProfiler.Begin("Physics"))
		{
		let pw = mScene?.GetComponent<PhysicsWorld>();
		if (pw != null)
		{
			pw.StepSimulation(timeStep);
			for (let rb in mDynamicBodies)
				rb.SyncFromPhysics();
		}
		} // Profiler: Physics

		let shell = Context.GetSubsystem<IShell>();
		if (shell == null) return;

		let mouse = shell.InputManager.Mouse;
		let kb = shell.InputManager.Keyboard;

		// Escape to exit
		if (kb.IsKeyPressed(.Escape))
		{
			Exit();
			return;
		}

		// Mouse look (right-click drag)
		if (mouse.IsButtonDown(.Right))
		{
			mYaw += mouse.DeltaX * 0.1f;
			mPitch += mouse.DeltaY * 0.1f;
			mPitch = Math.Clamp(mPitch, -89.0f, 89.0f);
		}

		let yawRad = mYaw * (Math.PI_f / 180.0f);
		let pitchRad = mPitch * (Math.PI_f / 180.0f);
		let rotation = Quaternion.CreateFromYawPitchRoll(yawRad, pitchRad, 0);
		mCameraNode.Rotation = rotation;

		// WASD movement in local space
		float speed = 20.0f * timeStep;
		var pos = mCameraNode.Position;

		if (kb.IsKeyDown(.W))
			pos += Vector3.Transform(Vector3.Forward, rotation) * speed;
		if (kb.IsKeyDown(.S))
			pos += Vector3.Transform(.(0, 0, 1), rotation) * speed;
		if (kb.IsKeyDown(.A))
			pos += Vector3.Transform(.(-1, 0, 0), rotation) * speed;
		if (kb.IsKeyDown(.D))
			pos += Vector3.Transform(.(1, 0, 0), rotation) * speed;
		if (kb.IsKeyDown(.E))
			pos += Vector3(0, 1, 0) * speed;
		if (kb.IsKeyDown(.Q))
			pos += Vector3(0, -1, 0) * speed;

		mCameraNode.Position = pos;

		// DEBUG: Draw bounding boxes for particles and sprite, and light gizmos
		if (mDebugRenderer != null)
		{
			mDebugRenderer.BeginFrame();

			let octree = mScene.GetComponent<Octree>();
			if (octree != null)
			{
				let drawables = scope List<Drawable>();
				octree.QueryBox(BoundingBox(Vector3(-500), Vector3(500)), drawables, .Geometry);
				for (let d in drawables)
				{
					if (d is Sprite2D)
					{
						// World bounding box in yellow (no depth test = always visible)
						mDebugRenderer.AddBoundingBox(d.WorldBoundingBox, Color.Yellow, depthTest: false);
						// Node position cross in cyan
						if (d.Node != null)
							mDebugRenderer.AddCross(d.Node.WorldPosition, 0.5f, Color.Cyan, depthTest: false);
					}
				}

				// Draw light gizmos
				let lights = scope List<Drawable>();
				octree.QueryBox(BoundingBox(Vector3(-500), Vector3(500)), lights, .Light);
				for (let d in lights)
				{
					if (let light = d as Light)
					{
						let lightPos = light.WorldPosition;

						switch (light.LightType)
						{
						case .Point:
							// Sphere showing range
							mDebugRenderer.AddSphere(lightPos, light.Range, Color(0.4f, 0.6f, 1.0f), depthTest: false, segments: 16);
							mDebugRenderer.AddCross(lightPos, 0.5f, Color(0.4f, 0.6f, 1.0f), depthTest: false);

						case .Spot:
							// Cone: apex at light position, opening along light direction
							let dir = light.Direction;
							let range = light.Range;
							let halfFov = light.SpotFov * 0.5f;
							let endRadius = Math.Tan(halfFov) * range;
							let endCenter = lightPos + dir * range;

							// Build a local coordinate frame perpendicular to the light direction
							var up = Vector3.Up;
							if (Math.Abs(Vector3.Dot(dir, up)) > 0.99f)
								up = Vector3.Right;
							let right = Vector3.Normalize(Vector3.Cross(dir, up));
							let orthoUp = Vector3.Cross(right, dir);

							// Draw cone outline: 8 lines from apex to base circle
							let coneColor = Color(1.0f, 0.9f, 0.3f);
							int coneSegments = 16;
							for (int i = 0; i < coneSegments; i++)
							{
								float a0 = Math.PI_f * 2.0f * (float)i / (float)coneSegments;
								float a1 = Math.PI_f * 2.0f * (float)(i + 1) / (float)coneSegments;
								let p0 = endCenter + (right * Math.Cos(a0) + orthoUp * Math.Sin(a0)) * endRadius;
								let p1 = endCenter + (right * Math.Cos(a1) + orthoUp * Math.Sin(a1)) * endRadius;
								// Base circle segment
								mDebugRenderer.AddLine(p0, p1, coneColor, depthTest: false);
								// Rays from apex (every 4th segment)
								if (i % 4 == 0)
									mDebugRenderer.AddLine(lightPos, p0, coneColor, depthTest: false);
							}
							mDebugRenderer.AddCross(lightPos, 0.5f, coneColor, depthTest: false);

						case .Directional:
							// Just a cross + direction arrow
							let camPos = mCameraNode.Position;
							let arrowStart = camPos + .(0, 5, 0);
							mDebugRenderer.AddLine(arrowStart, arrowStart + light.Direction * 5.0f, Color(1.0f, 1.0f, 0.5f), depthTest: false);
							mDebugRenderer.AddCross(arrowStart, 0.3f, Color(1.0f, 1.0f, 0.5f), depthTest: false);
						}
					}
				}

				// Draw navigation debug: path lines + agent velocity vectors
				if (mDebugPath.Count > 1)
				{
					let pathColor = Color(0.0f, 1.0f, 0.0f);
					for (int i = 0; i < mDebugPath.Count - 1; i++)
					{
						var p0 = mDebugPath[i]; p0.Y += 0.1f;
						var p1 = mDebugPath[i + 1]; p1.Y += 0.1f;
						mDebugRenderer.AddLine(p0, p1, pathColor, depthTest: false);
					}
					// Waypoint markers
					for (let wp in mDebugPath)
					{
						var wpVis = wp; wpVis.Y += 0.1f;
						mDebugRenderer.AddCross(wpVis, 0.2f, pathColor, depthTest: false);
					}
				}

				// Agent velocity arrows + position markers
				for (let agent in mCrowdAgents)
				{
					let agentPos = agent.CrowdPosition;
					let vel = agent.Velocity;
					var drawPos = agentPos; drawPos.Y = 0.5f;
					// Velocity arrow (cyan)
					if (vel.LengthSquared() > 0.01f)
						mDebugRenderer.AddLine(drawPos, drawPos + vel * 0.5f, Color(0.0f, 1.0f, 1.0f), depthTest: false);
					// Agent position cross (white)
					mDebugRenderer.AddCross(drawPos, agent.Radius, Color.White, depthTest: false);
				}
			}
		}

		// DEBUG: Press P to dump frustum culling diagnostics
		if (kb.IsKeyPressed(.P))
		{
			let camera = mCameraNode.GetComponent<Camera>();
			if (camera != null)
			{
				let frustum = camera.Frustum;
				let culler = FrustumCuller(frustum);
				let vp = camera.ViewProjectionMatrix;
				Console.WriteLine(scope $"=== FRUSTUM DEBUG (pitch={mPitch:F1} yaw={mYaw:F1}) cam=({pos.X:F1},{pos.Y:F1},{pos.Z:F1}) ===");
				Console.WriteLine(scope $"VP row0: ({vp.M11:F4},{vp.M12:F4},{vp.M13:F4},{vp.M14:F4})");
				Console.WriteLine(scope $"VP row1: ({vp.M21:F4},{vp.M22:F4},{vp.M23:F4},{vp.M24:F4})");
				Console.WriteLine(scope $"VP row2: ({vp.M31:F4},{vp.M32:F4},{vp.M33:F4},{vp.M34:F4})");
				Console.WriteLine(scope $"VP row3: ({vp.M41:F4},{vp.M42:F4},{vp.M43:F4},{vp.M44:F4})");

				String[6] planeNames = .("Near", "Far", "Left", "Right", "Top", "Bottom");
				for (int pi = 0; pi < 6; pi++)
					Console.WriteLine(scope $"  {planeNames[pi]}: inward=({culler.Planes[pi].X:F4},{culler.Planes[pi].Y:F4},{culler.Planes[pi].Z:F4},{culler.Planes[pi].W:F4})");

				let octree = mScene.GetComponent<Octree>();
				if (octree != null)
				{
					let all = scope List<Drawable>();
					octree.QueryBox(BoundingBox(Vector3(-500), Vector3(500)), all, .Geometry);
					int visible = 0;
					int[6] rejectedByPlane = default;
					for (let d in all)
					{
						let bb = d.WorldBoundingBox;
						if (culler.TestAABB(bb))
						{
							visible++;
						}
						else
						{
							// Find which plane rejects it
							for (int pi = 0; pi < 6; pi++)
							{
								float px = culler.PosX[pi] ? bb.Max.X : bb.Min.X;
								float py = culler.PosY[pi] ? bb.Max.Y : bb.Min.Y;
								float pz = culler.PosZ[pi] ? bb.Max.Z : bb.Min.Z;
								let dot = culler.Planes[pi].X * px + culler.Planes[pi].Y * py + culler.Planes[pi].Z * pz + culler.Planes[pi].W;
								if (dot < 0)
								{
									rejectedByPlane[pi]++;
									break;
								}
							}
						}
					}
					Console.WriteLine(scope $"  Total geometry: {all.Count}, visible: {visible}, culled: {all.Count - visible}");
					for (int pi = 0; pi < 6; pi++)
						if (rejectedByPlane[pi] > 0)
							Console.WriteLine(scope $"  Rejected by {planeNames[pi]}: {rejectedByPlane[pi]}");

					// Check how many drawables have valid batches/buffers
					int nullMesh = 0, nullVB = 0, nullIB = 0, nullMat = 0, emptyBatches = 0, totalBatches = 0;
					for (let d in all)
					{
						let batches = d.Batches;
						if (batches.Length == 0)
						{
							emptyBatches++;
							continue;
						}
						for (let b in batches)
						{
							totalBatches++;
							if (b.VertexBuffer == null) nullVB++;
							if (b.IndexBuffer == null) nullIB++;
							if (b.Material == null) nullMat++;
						}
					}
					Console.WriteLine(scope $"  Batch details: totalBatches={totalBatches} emptyBatchDrawables={emptyBatches} nullVB={nullVB} nullIB={nullIB} nullMat={nullMat}");
				}

				// Print renderer pipeline stats (from previous frame)
				Console.WriteLine(scope $"  RENDERER: visGeometry={mRenderer.StatVisibleGeometry} opaque={mRenderer.StatOpaqueBatches} transparent={mRenderer.StatTransparentBatches} drawCalls={mRenderer.StatDrawCalls}");
			}
		}

		// F1: Print profiler output
		if (kb.IsKeyPressed(.F1))
		{
			let frame = SProfiler.GetCompletedFrame();
			if (frame != null)
			{
				Console.WriteLine(scope $"=== PROFILER FRAME {frame.FrameNumber} ({frame.FrameDurationMs:F2}ms) ===");
				for (let sample in frame.Samples)
				{
					let indent = scope String();
					for (int d = 0; d < sample.Depth; d++)
						indent.Append("  ");
					Console.WriteLine(scope $"  {indent}{sample.Name}: {sample.DurationMs:F3}ms");
				}
			}
		}
		} // Profiler: App.OnUpdate
	}

	private void OnRender()
	{
		using (SProfiler.Begin("App.OnRender"))
		{
		mRenderer.Update(Engine.DeltaTime);
		// DEBUG: Full GPU sync to detect buffer thrashing
		//Device.WaitIdle();
		mRenderer.Render(SwapChain);
		} // Profiler: App.OnRender
	}

	private void OnResize(int32 width, int32 height)
	{
		mRenderer.SetBackbufferSize(width, height);
	}

	protected override void Stop()
	{
		Logger?.LogInformation("Stopping Static Scene demo...");
		SProfiler.Shutdown();

		if (mRenderer != null)
		{
			mRenderer.Shutdown();
			delete mRenderer;
			mRenderer = null;
		}

		// Clear post-process stack reference before deleting viewport
		if (mViewport != null && mPostProcessStack != null)
			mViewport.PostProcessStack = null;

		if (mViewport != null)
		{
			delete mViewport;
			mViewport = null;
		}

		// Post-processing cleanup
		// PostProcessStack owns its effects (DeleteContainerAndItems), so don't delete mToneMapEffect separately
		if (mPostProcessStack != null)
		{
			delete mPostProcessStack;
			mPostProcessStack = null;
			mToneMapEffect = null; // Owned and deleted by the stack
		}

		// mMaterialInstances, mMeshes cleaned up by field destructors
		// Material templates must be deleted after instances
		if (mParticleMaterial != null)
		{
			delete mParticleMaterial;
			mParticleMaterial = null;
		}
		if (mSpriteMaterial != null)
		{
			delete mSpriteMaterial;
			mSpriteMaterial = null;
		}
		if (mTrailMaterial != null)
		{
			delete mTrailMaterial;
			mTrailMaterial = null;
		}
		if (mDecalMaterial != null)
		{
			delete mDecalMaterial;
			mDecalMaterial = null;
		}
		if (mSpriteTextureView != null)
		{
			delete mSpriteTextureView;
			mSpriteTextureView = null;
		}
		if (mSpriteTexture != null)
		{
			delete mSpriteTexture;
			mSpriteTexture = null;
		}
		if (mSkyboxTextureView != null)
		{
			delete mSkyboxTextureView;
			mSkyboxTextureView = null;
		}
		if (mSkyboxTexture != null)
		{
			delete mSkyboxTexture;
			mSkyboxTexture = null;
		}
		if (mPbrMaterial != null)
		{
			delete mPbrMaterial;
			mPbrMaterial = null;
		}

		if (mScene != null)
		{
			delete mScene;
			mScene = null;
		}

		// Delete import results after scene (components reference meshes/skeletons/clips)
		for (let r in mImportResults)
			delete r;
		mImportResults.Clear();

		// Delete model GPU textures/views after material instances are gone
		for (let v in mModelTextureViews)
			delete v;
		mModelTextureViews.Clear();
		for (let t in mModelTextures)
			delete t;
		mModelTextures.Clear();

		// Shutdown model loaders
		if (GltfModels.IsInitialized)
			GltfModels.Shutdown();
		if (FbxModels.IsInitialized)
			FbxModels.Shutdown();

		// Delete Jolt world after scene (PhysicsWorld component may reference it during teardown)
		if (mJoltWorld != null)
		{
			delete mJoltWorld;
			mJoltWorld = null;
		}
	}
}

class Program
{
	static void Main()
	{
		let app = scope DemoApp();
		let exitCode = app.Run();
		if (exitCode != 0)
			Console.Error.WriteLine(scope $"Application exited with code {exitCode}");
	}
}
