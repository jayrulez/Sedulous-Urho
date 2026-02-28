using System;
using System.Collections;
using Sedulous.RHI;
using Sedulous.Shaders;
using Sedulous.Materials;

namespace Sedulous.Engine.Renderer;

/// Caches compiled render pipelines keyed by PipelineConfig.
///
/// Creating render pipelines is expensive in Vulkan. This cache maps a
/// PipelineConfig (shader + render state + vertex layout + target format)
/// to a compiled IRenderPipeline so identical configurations reuse the
/// same pipeline object.
///
public class PipelineStateCache
{
	private IDevice mDevice;
	private ShaderSystem mShaderSystem;
	private Dictionary<int, IRenderPipeline> mCache = new .() ~ {
		for (let kv in _)
			delete kv.value;
		delete _;
	};
	private Dictionary<int, IPipelineLayout> mLayoutCache = new .() ~ {
		for (let kv in _)
			delete kv.value;
		delete _;
	};

	public this(IDevice device, ShaderSystem shaderSystem)
	{
		mDevice = device;
		mShaderSystem = shaderSystem;
	}

	/// Gets or creates a compiled render pipeline for the given config and bind group layouts.
	/// materialLayout: Bind group layout for material properties (slot 0).
	/// frameLayout: Bind group layout for per-frame uniforms (slot 1, optional).
	/// objectLayout: Bind group layout for per-object uniforms (slot 2, optional).
	/// boneLayout: Bind group layout for bone matrices (slot 3, optional, skinned meshes).
	public Result<IRenderPipeline> GetOrCreate(PipelineConfig config,
		IBindGroupLayout materialLayout = null,
		IBindGroupLayout frameLayout = null,
		IBindGroupLayout objectLayout = null,
		IBindGroupLayout boneLayout = null)
	{
		let key = ComputePipelineKey(config, materialLayout, frameLayout, objectLayout, boneLayout);

		if (mCache.TryGetValue(key, let cached))
			return cached;

		// Compile shaders
		let shaderPair = mShaderSystem.GetShaderPair(config.ShaderName, config.ShaderFlags);
		if (shaderPair case .Err)
			return .Err;

		let vertModule = shaderPair.Value.vert.GetRhiModule(mDevice);
		let fragModule = shaderPair.Value.frag.GetRhiModule(mDevice);
		if (vertModule case .Err)
			return .Err;
		if (fragModule case .Err)
			return .Err;

		// Build pipeline layout
		let pipelineLayout = GetOrCreateLayout(materialLayout, frameLayout, objectLayout, boneLayout);
		if (pipelineLayout case .Err)
			return .Err;

		// Build vertex state (with optional instance buffer for GPU instancing)
		VertexState vertexState;
		VertexBufferLayout[1] singleLayout = default;
		VertexBufferLayout[2] instancedLayout = default;

		if (config.ShaderFlags.HasFlag(.Instanced))
		{
			// Two vertex buffers: per-vertex (slot 0) + per-instance (slot 1)
			VertexLayoutHelper.CreateInstancedMeshLayout(config.VertexLayout, out instancedLayout);
			vertexState = .()
			{
				Shader = .(vertModule.Value, "main"),
				Buffers = instancedLayout
			};
		}
		else
		{
			singleLayout = .(VertexLayoutHelper.CreateBufferLayout(config.VertexLayout));
			vertexState = .()
			{
				Shader = .(vertModule.Value, "main"),
				Buffers = singleLayout
			};
		}

		// Build fragment state (skip for depth-only)
		FragmentState? fragmentState = null;
		ColorTargetState[1] colorTargets = default;
		if (!config.DepthOnly)
		{
			colorTargets = .(ColorTargetState()
			{
				Format = config.ColorFormat,
				Blend = GetBlendState(config.BlendMode),
				WriteMask = config.ColorWriteMask
			});

			fragmentState = FragmentState()
			{
				Shader = .(fragModule.Value, "main"),
				Targets = colorTargets
			};
		}

		// Build primitive state
		PrimitiveState primitiveState = .()
		{
			Topology = config.Topology,
			FrontFace = config.FrontFace,
			CullMode = GetCullMode(config.CullMode),
			FillMode = config.FillMode
		};

		// Build depth/stencil state
		DepthStencilState? depthStencilState = null;
		if (config.DepthMode != .Disabled)
		{
			depthStencilState = DepthStencilState()
			{
				Format = config.DepthFormat,
				DepthTestEnabled = config.DepthMode != .WriteOnly,
				DepthWriteEnabled = config.DepthMode == .ReadWrite || config.DepthMode == .WriteOnly,
				DepthCompare = config.DepthCompare,
				DepthBias = (int32)config.DepthBias,
				DepthBiasSlopeScale = config.DepthBiasSlopeScale
			};
		}

		// Build multisample state
		MultisampleState multisampleState = .()
		{
			Count = (uint32)config.SampleCount
		};

		// Create descriptor
		var desc = RenderPipelineDescriptor()
		{
			Layout = pipelineLayout.Value,
			Vertex = vertexState,
			Fragment = fragmentState,
			Primitive = primitiveState,
			DepthStencil = depthStencilState,
			Multisample = multisampleState,
			Label = config.ShaderName
		};

		if (mDevice.CreateRenderPipeline(&desc) case .Ok(let pipeline))
		{
			mCache[key] = pipeline;
			return pipeline;
		}

		return .Err;
	}

	/// Clears all cached pipelines (e.g. on device lost or shader reload).
	public void Invalidate()
	{
		for (let kv in mCache)
			delete kv.value;
		mCache.Clear();

		for (let kv in mLayoutCache)
			delete kv.value;
		mLayoutCache.Clear();
	}

	/// Number of cached pipelines.
	public int Count => mCache.Count;

	// ===== Private =====

	private int ComputePipelineKey(PipelineConfig config,
		IBindGroupLayout materialLayout, IBindGroupLayout frameLayout, IBindGroupLayout objectLayout,
		IBindGroupLayout boneLayout = null)
	{
		int key = config.GetHashCode();
		if (materialLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(materialLayout).GetHashCode();
		if (frameLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(frameLayout).GetHashCode();
		if (objectLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(objectLayout).GetHashCode();
		if (boneLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(boneLayout).GetHashCode();
		return key;
	}

	private int ComputeLayoutKey(IBindGroupLayout materialLayout, IBindGroupLayout frameLayout,
		IBindGroupLayout objectLayout, IBindGroupLayout boneLayout = null)
	{
		int key = 17;
		if (materialLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(materialLayout).GetHashCode();
		if (frameLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(frameLayout).GetHashCode();
		if (objectLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(objectLayout).GetHashCode();
		if (boneLayout != null)
			key = key * 31 + Internal.UnsafeCastToPtr(boneLayout).GetHashCode();
		return key;
	}

	private Result<IPipelineLayout> GetOrCreateLayout(
		IBindGroupLayout materialLayout, IBindGroupLayout frameLayout,
		IBindGroupLayout objectLayout, IBindGroupLayout boneLayout = null)
	{
		int layoutKey = ComputeLayoutKey(materialLayout, frameLayout, objectLayout, boneLayout);

		if (mLayoutCache.TryGetValue(layoutKey, let cached))
			return cached;

		// Build layout array: slot 0 = material, slot 1 = frame, slot 2 = object, slot 3 = bones
		var layoutList = scope List<IBindGroupLayout>();
		if (materialLayout != null) layoutList.Add(materialLayout);
		if (frameLayout != null) layoutList.Add(frameLayout);
		if (objectLayout != null) layoutList.Add(objectLayout);
		if (boneLayout != null) layoutList.Add(boneLayout);

		if (layoutList.Count > 0)
		{
			Span<IBindGroupLayout> layouts = .(layoutList.Ptr, layoutList.Count);
			PipelineLayoutDescriptor layoutDesc = .(layouts);
			if (mDevice.CreatePipelineLayout(&layoutDesc) case .Ok(let layout))
			{
				mLayoutCache[layoutKey] = layout;
				return layout;
			}
			return .Err;
		}
		else
		{
			// Empty layout
			PipelineLayoutDescriptor layoutDesc = .(default);
			if (mDevice.CreatePipelineLayout(&layoutDesc) case .Ok(let layout))
			{
				mLayoutCache[layoutKey] = layout;
				return layout;
			}
			return .Err;
		}
	}

	private static BlendState? GetBlendState(BlendMode mode)
	{
		switch (mode)
		{
		case .Opaque:
			return null;
		case .AlphaBlend:
			return BlendState()
			{
				Color = .()
				{
					SrcFactor = .SrcAlpha,
					DstFactor = .OneMinusSrcAlpha,
					Operation = .Add
				},
				Alpha = .()
				{
					SrcFactor = .One,
					DstFactor = .OneMinusSrcAlpha,
					Operation = .Add
				}
			};
		case .Additive:
			return BlendState()
			{
				Color = .()
				{
					SrcFactor = .One,
					DstFactor = .One,
					Operation = .Add
				},
				Alpha = .()
				{
					SrcFactor = .One,
					DstFactor = .One,
					Operation = .Add
				}
			};
		case .Multiply:
			return BlendState()
			{
				Color = .()
				{
					SrcFactor = .Dst,
					DstFactor = .Zero,
					Operation = .Add
				},
				Alpha = .()
				{
					SrcFactor = .DstAlpha,
					DstFactor = .Zero,
					Operation = .Add
				}
			};
		case .PremultipliedAlpha:
			return BlendState()
			{
				Color = .()
				{
					SrcFactor = .One,
					DstFactor = .OneMinusSrcAlpha,
					Operation = .Add
				},
				Alpha = .()
				{
					SrcFactor = .One,
					DstFactor = .OneMinusSrcAlpha,
					Operation = .Add
				}
			};
		}
	}

	private static CullMode GetCullMode(CullModeConfig config)
	{
		switch (config)
		{
		case .None: return .None;
		case .Back: return .Back;
		case .Front: return .Front;
		}
	}
}
