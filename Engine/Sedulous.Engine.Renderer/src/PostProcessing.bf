using System;
using System.Collections;
using Sedulous.Foundation.Mathematics;
using Sedulous.RHI;
using Sedulous.RenderGraph;

namespace Sedulous.Engine.Renderer;

/// Base class for a post-processing effect.
///
/// Each effect adds one or more fullscreen passes to the render graph.
/// Effects are chained: the output of one is the input of the next.
///
public abstract class PostProcessEffect
{
	/// Whether this effect is enabled.
	public bool Enabled = true;

	/// Display name for debug/UI.
	public abstract StringView Name { get; }

	/// Adds this effect's passes to the render graph.
	/// inputColor: handle to the current scene color texture.
	/// Returns: handle to the output color texture (may be same or different).
	public abstract ResourceHandle Apply(RenderGraph graph, ResourceHandle inputColor,
		uint32 width, uint32 height, int32 frameIndex);

	/// Adds this effect's passes with an explicit output target.
	/// Override this when the effect can write directly to a specified target
	/// (e.g., the backbuffer) instead of creating its own output.
	/// Default implementation ignores outputTarget and calls the regular Apply.
	public virtual ResourceHandle ApplyTo(RenderGraph graph, ResourceHandle inputColor,
		ResourceHandle outputTarget, uint32 width, uint32 height, int32 frameIndex)
	{
		return Apply(graph, inputColor, width, height, frameIndex);
	}
}

/// Tone mapping methods.
public enum ToneMapMethod
{
	/// No tone mapping (pass-through).
	None,
	/// Reinhard tone mapping.
	Reinhard,
	/// ACES filmic tone mapping.
	ACES,
	/// Exposure-only (simple multiply).
	Exposure
}

/// GPU-compatible tone map uniform data (16 bytes, std140).
[CRepr]
public struct ToneMapUniformData
{
	public float Exposure;
	public float Gamma;
	public float Method;
	public float Pad;
}

/// Tone mapping post-process effect.
///
/// Converts HDR color values to LDR for display. Configurable method
/// and exposure. Applied as a fullscreen pass that samples the scene
/// HDR texture and writes the tonemapped result.
///
public class ToneMapEffect : PostProcessEffect
{
	private const int32 MAX_FRAMES = FrameConfig.MAX_FRAMES_IN_FLIGHT;

	/// Tone mapping method.
	public ToneMapMethod Method = .ACES;
	/// Exposure multiplier.
	public float Exposure = 1.0f;
	/// Gamma correction (2.2 for sRGB).
	public float Gamma = 2.2f;

	// GPU resources (initialized by Renderer)
	private IDevice mDevice;
	private IRenderPipeline mPipeline;
	private IBindGroupLayout mBindGroupLayout ~ { if (_ != null) delete _; };
	private IBuffer[MAX_FRAMES] mUniformBuffers ~ { for (let b in _) if (b != null) delete b; };
	private ISampler mLinearSampler ~ { if (_ != null) delete _; };
	private IBindGroup[MAX_FRAMES] mCachedBindGroups ~ { for (let bg in _) if (bg != null) delete bg; };

	public override StringView Name => "ToneMapping";

	/// The render pipeline (set by Renderer during initialization).
	public IRenderPipeline Pipeline { get => mPipeline; set => mPipeline = value; }

	/// Initializes GPU resources for tone mapping.
	/// Called by the Renderer after shader compilation.
	public Result<void> InitializeGPU(IDevice device, IRenderPipeline pipeline)
	{
		mDevice = device;
		mPipeline = pipeline;

		// Create uniform buffers (one per frame in flight)
		for (int32 i = 0; i < MAX_FRAMES; i++)
		{
			var bufDesc = BufferDescriptor((uint64)sizeof(ToneMapUniformData), .Uniform | .CopyDst, .Upload);
			if (device.CreateBuffer(&bufDesc) case .Ok(let buf))
				mUniformBuffers[i] = buf;
			else
				return .Err;
		}

		// Create linear sampler
		var samplerDesc = SamplerDescriptor();
		samplerDesc.MinFilter = .Linear;
		samplerDesc.MagFilter = .Linear;
		samplerDesc.MipmapFilter = .Nearest;
		samplerDesc.AddressModeU = .ClampToEdge;
		samplerDesc.AddressModeV = .ClampToEdge;
		samplerDesc.Label = "ToneMapSampler";
		if (device.CreateSampler(&samplerDesc) case .Ok(let sampler))
			mLinearSampler = sampler;
		else
			return .Err;

		// Create bind group layout: uniform buffer (b0) + texture (t0) + sampler (s0)
		BindGroupLayoutEntry[3] layoutEntries = .(
			.UniformBuffer(0, .Fragment),
			.SampledTexture(0, .Fragment),
			.Sampler(0, .Fragment)
		);
		var layoutDesc = BindGroupLayoutDescriptor(layoutEntries);
		if (device.CreateBindGroupLayout(&layoutDesc) case .Ok(let layout))
			mBindGroupLayout = layout;
		else
			return .Err;

		return .Ok;
	}

	/// The bind group layout for pipeline creation (space0 for tonemap).
	public IBindGroupLayout BindGroupLayout => mBindGroupLayout;

	public override ResourceHandle Apply(RenderGraph graph, ResourceHandle inputColor,
		uint32 width, uint32 height, int32 frameIndex)
	{
		return ApplyTo(graph, inputColor, inputColor, width, height, frameIndex);
	}

	public override ResourceHandle ApplyTo(RenderGraph graph, ResourceHandle inputColor,
		ResourceHandle outputTarget, uint32 width, uint32 height, int32 frameIndex)
	{
		let fi = frameIndex % MAX_FRAMES;
		if (mPipeline == null || mDevice == null || mUniformBuffers[fi] == null)
			return inputColor;

		// Upload uniform data to this frame's buffer
		var data = ToneMapUniformData();
		data.Exposure = Exposure;
		data.Gamma = Gamma;
		data.Method = (float)Method;
		data.Pad = 0;
		mDevice.Queue.WriteBuffer(mUniformBuffers[fi], 0,
			Span<uint8>((uint8*)&data, sizeof(ToneMapUniformData)));

		// Add the tonemap render pass
		ResourceHandle result = .Invalid;

		graph.AddRasterPass("ToneMap",
			new [&result, =inputColor, =outputTarget] (builder) =>
			{
				builder.Read(inputColor);
				result = builder.SetColorAttachment(0, outputTarget, .DontCare);
				builder.SideEffect();
			},
			new (encoder) =>
			{
				// Resolve the scene HDR texture view from the render graph (valid after Compile)
				let sceneView = graph.GetTextureView(inputColor);
				if (sceneView == null || mLinearSampler == null)
					return;

				// Free this frame slot's previous bind group (GPU finished with it —
				// we waited on its fence in AcquireNextImage before reaching here)
				if (mCachedBindGroups[fi] != null)
				{
					delete mCachedBindGroups[fi];
					mCachedBindGroups[fi] = null;
				}

				// Create bind group with the resolved texture view
				BindGroupEntry[3] entries = .(
					.Buffer(0, mUniformBuffers[fi], 0, (uint64)sizeof(ToneMapUniformData)),
					.Texture(0, sceneView, .ShaderReadOnly),
					.Sampler(0, mLinearSampler)
				);
				var bgDesc = BindGroupDescriptor(mBindGroupLayout, entries);
				if (mDevice.CreateBindGroup(&bgDesc) case .Ok(let bindGroup))
				{
					mCachedBindGroups[fi] = bindGroup;
					encoder.SetPipeline(mPipeline);
					encoder.SetBindGroup(0, bindGroup);
					encoder.Draw(3, 1, 0, 0); // Fullscreen triangle
				}
			}
		);

		return result;
	}
}

/// Bloom post-process effect.
///
/// Extracts bright pixels, blurs them, and composites back onto the scene.
/// Uses a bright-pass threshold and configurable intensity.
///
public class BloomEffect : PostProcessEffect
{
	/// Brightness threshold for bloom extraction.
	public float Threshold = 1.0f;
	/// Bloom intensity multiplier.
	public float Intensity = 0.5f;
	/// Number of blur iterations.
	public int32 BlurIterations = 4;

	// Pipelines (set externally)
	public IRenderPipeline BrightPassPipeline;
	public IRenderPipeline BlurPipeline;
	public IRenderPipeline CompositePipeline;
	public IBindGroup BrightPassBindGroup;
	public IBindGroup BlurBindGroup;
	public IBindGroup CompositeBindGroup;

	public override StringView Name => "Bloom";

	public override ResourceHandle Apply(RenderGraph graph, ResourceHandle inputColor,
		uint32 width, uint32 height, int32 frameIndex)
	{
		if (BrightPassPipeline == null || BlurPipeline == null || CompositePipeline == null)
			return inputColor;

		// Step 1: Extract bright pixels
		let halfWidth = Math.Max(width / 2, 1u);
		let halfHeight = Math.Max(height / 2, 1u);

		let bloomDesc = TextureDescriptor.Texture2D(halfWidth, halfHeight, .RGBA16Float, .RenderTarget | .Sampled);
		let bloomTex = graph.CreateTexture("BloomBright", bloomDesc);

		BuiltinPasses.AddFullscreenPass(graph, "BloomBrightPass", inputColor, bloomTex,
			BrightPassPipeline, BrightPassBindGroup);

		// Step 2: Blur (ping-pong)
		let blurDesc = TextureDescriptor.Texture2D(halfWidth, halfHeight, .RGBA16Float, .RenderTarget | .Sampled);
		let blurTex = graph.CreateTexture("BloomBlur", blurDesc);

		var src = bloomTex;
		var dst = blurTex;
		for (int32 i = 0; i < BlurIterations; i++)
		{
			BuiltinPasses.AddFullscreenPass(graph, "BloomBlur", src, dst, BlurPipeline, BlurBindGroup);
			let temp = src;
			src = dst;
			dst = temp;
		}

		// Step 3: Composite bloom onto scene
		return BuiltinPasses.AddFullscreenPass(graph, "BloomComposite", src, inputColor,
			CompositePipeline, CompositeBindGroup);
	}
}

/// Ordered stack of post-processing effects applied to a viewport.
///
/// Effects are applied in order. Each effect reads the previous output
/// and writes a new (or in-place) result. Attach to a Viewport to
/// enable post-processing for that view.
///
public class PostProcessStack
{
	private List<PostProcessEffect> mEffects = new .() ~ DeleteContainerAndItems!(_);

	/// Adds an effect to the end of the stack.
	public void AddEffect(PostProcessEffect effect)
	{
		mEffects.Add(effect);
	}

	/// Removes an effect from the stack.
	public void RemoveEffect(PostProcessEffect effect)
	{
		mEffects.Remove(effect);
	}

	/// Gets the effect at the given index.
	public PostProcessEffect GetEffect(int index)
	{
		if (index >= 0 && index < mEffects.Count)
			return mEffects[index];
		return null;
	}

	/// Number of effects in the stack.
	public int Count => mEffects.Count;

	/// Applies all enabled effects to the render graph.
	/// Returns the final output handle.
	public ResourceHandle Apply(RenderGraph graph, ResourceHandle inputColor,
		uint32 width, uint32 height, int32 frameIndex)
	{
		var current = inputColor;

		for (let effect in mEffects)
		{
			if (effect.Enabled)
				current = effect.Apply(graph, current, width, height, frameIndex);
		}

		return current;
	}

	/// Applies all enabled effects, routing the last effect's output to finalOutput.
	/// inputColor: HDR scene texture.
	/// finalOutput: display target (e.g., backbuffer).
	public ResourceHandle Apply(RenderGraph graph, ResourceHandle inputColor,
		ResourceHandle finalOutput, uint32 width, uint32 height, int32 frameIndex)
	{
		var current = inputColor;

		// Find the last enabled effect index
		int lastEnabledIdx = -1;
		for (int i = mEffects.Count - 1; i >= 0; i--)
		{
			if (mEffects[i].Enabled) { lastEnabledIdx = i; break; }
		}

		if (lastEnabledIdx < 0)
			return inputColor; // No enabled effects

		for (int i = 0; i < mEffects.Count; i++)
		{
			let effect = mEffects[i];
			if (!effect.Enabled)
				continue;

			if (i == lastEnabledIdx)
				current = effect.ApplyTo(graph, current, finalOutput, width, height, frameIndex);
			else
				current = effect.Apply(graph, current, width, height, frameIndex);
		}

		return current;
	}
}
