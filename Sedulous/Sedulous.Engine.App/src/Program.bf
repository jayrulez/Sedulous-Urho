using System;
using System.Collections;
using Sedulous.Engine.Core;
using Sedulous.Engine.Renderer;
using Sedulous.Engine.Physics;
using Sedulous.Engine.Physics.Jolt;
using Sedulous.Foundation.Mathematics;
using Sedulous.Geometry;
using Sedulous.Materials;
using Sedulous.Shell;
using Sedulous.Shell.Input;

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

	protected override void Setup()
	{
		Parameters.WindowTitle = "Sedulous - Static Scene";
		Parameters.WindowWidth = 1280;
		Parameters.WindowHeight = 720;
	}

	protected override void Start()
	{
		Logger?.LogInformation("Starting Static Scene demo...");

		// --- Initialize Renderer ---
		mRenderer = new Renderer(Logger);
		let shaderPath = scope String();
		GetAssetPath("Shaders", shaderPath);
		if (mRenderer.Initialize(Device, scope StringView[](shaderPath)) case .Err)
		{
			Logger?.LogCritical("Failed to initialize renderer.");
			return;
		}
		mRenderer.SetBackbufferSize((int32)Window.Width, (int32)Window.Height);

		// --- Create Scene ---
		mScene = new Scene();
		mScene.CreateComponent<Octree>();

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

		// --- 200 Random Objects ---
		CreateObjects(200);

		// --- Viewport ---
		mViewport = new Viewport(mScene, camera);
		mRenderer.SetViewport(0, mViewport);

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

		let planeModel = planeNode.CreateComponent<StaticModel>();
		let planeMesh = StaticMesh.CreatePlane(1.0f, 1.0f, 1, 1);
		mMeshes.Add(planeMesh);
		planeModel.Mesh = planeMesh;

		if(CreateMaterialInstance(.(0.5f, 0.5f, 0.5f, 1.0f), 0.0f, 0.8f) case .Ok(let planeInst))
		{
			planeModel.SetMaterial(planeInst);
			planeModel.UploadToGPU(Device);
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
			model.UploadToGPU(Device);

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

	private void OnUpdate(float timeStep)
	{
		// Step physics and sync dynamic body transforms
		let pw = mScene?.GetComponent<PhysicsWorld>();
		if (pw != null)
		{
			pw.StepSimulation(timeStep);
			for (let rb in mDynamicBodies)
				rb.SyncFromPhysics();
		}

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

		mCameraNode.Position = pos;

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
	}

	private void OnRender()
	{
		mRenderer.Update(Engine.DeltaTime);
		// DEBUG: Full GPU sync to detect buffer thrashing
		Device.WaitIdle();
		mRenderer.Render(SwapChain);
	}

	private void OnResize(int32 width, int32 height)
	{
		mRenderer.SetBackbufferSize(width, height);
	}

	protected override void Stop()
	{
		Logger?.LogInformation("Stopping Static Scene demo...");

		if (mRenderer != null)
		{
			mRenderer.Shutdown();
			delete mRenderer;
			mRenderer = null;
		}

		if (mViewport != null)
		{
			delete mViewport;
			mViewport = null;
		}

		// mMaterialInstances, mMeshes cleaned up by field destructors
		// mPbrMaterial must be deleted after instances
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
