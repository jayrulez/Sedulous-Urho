# Render Performance Analysis

## Overview

This document captures performance analysis of the Sedulous.Render system, identifying bottlenecks and outlining paths for improvement.

**Test Setup:** FrameworkRender sample with instanced sphere grid, shared materials, no physics.

---

## Current Performance (After Optimization)

### Release Mode Benchmarks

| Objects | Frame Time | FPS | Notes |
|---------|-----------|-----|-------|
| 8,000 | 6.8ms | 147 | Well-balanced, no bottleneck |
| 24,000 | 9.7ms | 103 | Good scaling |
| 32,000 | 15.4ms | 65 | Batcher becoming bottleneck |
| 32,000 | ~22ms | 45 | Actual measured (includes present) |

### Frame Breakdown (32k objects, Release)

| Component | Time | % of Frame |
|-----------|------|------------|
| Batcher.Build | 5.98ms | 39% |
| Visibility.Resolve | 3.17ms | 21% |
| Scene.PostUpdate | 2.12ms | 14% |
| Render.BeginFrame | 0.94ms | 6% |
| UpdateLighting | 0.81ms | 5% |
| Graph.Execute (GPU) | 0.56ms | 4% |
| Other | ~1.8ms | 11% |

**Key Insight:** GPU is barely utilized (~0.56ms). CPU is the bottleneck.

---

## Optimization Applied: Skip Redundant Uniform Uploads

### Problem

For instanced rendering, per-object uniforms (world matrix, normal matrix) were being uploaded to GPU buffers even though the instance buffer already contains this data.

- `DepthPrepassFeature.PrepareObjectUniforms` - uploaded ALL objects
- `ForwardOpaqueFeature.PrepareObjectUniforms` - uploaded ALL objects AGAIN

With 8k objects: ~5ms wasted in release, ~9ms in debug.

### Solution

Skip per-object uniform uploads when instancing is active. Only upload for skinned meshes (which don't use instancing).

**Files Modified:**
- `Features/DepthPrepassFeature.bf` - Skip static mesh uniforms when `InstancingActive`
- `Features/ForwardOpaqueFeature.bf` - Skip static mesh uniforms when `depthFeature.InstancingActive`

### Results

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| PrepareUniforms | 2.58ms | 0.005ms | -99.8% |
| PrepareObjectUniforms | 2.48ms | 0.002ms | -99.9% |
| 8k Release FPS | 58 | 147 | +153% |
| Max objects @ 60 FPS | ~7k | ~28k | +300% |

---

## Current Bottlenecks

### 1. Batcher.Build (DrawBatcher.bf)

**What it does:** Sorts draw commands by material and mesh for batching/instancing.

**Scaling:** O(n log n) comparison sort, but cache effects cause super-linear scaling at high counts.

| Objects | Time | Scaling Factor |
|---------|------|----------------|
| 8k | 0.84ms | baseline |
| 24k | 1.91ms | 2.3x (expected ~4x) |
| 32k | 5.98ms | 7.1x (expected ~5x) |

**Why it's slow:**
- Comparison sort with pointer chasing (cache unfriendly)
- Re-sorts every frame even for static scenes
- Material pointer comparisons require memory indirection

### 2. Visibility.Resolve (VisibilityResolver.bf)

**What it does:** Frustum culling - tests every object against view frustum.

**Scaling:** O(n) linear, but cache effects at scale.

| Objects | Time |
|---------|------|
| 8k | 0.49ms |
| 24k | 1.11ms |
| 32k | 3.17ms |

**Why it's slow:**
- Tests every single object (no spatial hierarchy)
- Random memory access patterns for proxy data

### 3. Scene.PostUpdate (RenderSceneModule.bf)

**What it does:** Syncs scene entity transforms to RenderWorld proxies.

**Scaling:** O(n) - iterates all entities with mesh components.

| Objects | Time |
|---------|------|
| 8k | 0.58ms |
| 24k | 1.10ms |
| 32k | 2.12ms |

**Why it's slow:**
- Syncs ALL objects every frame, even if unchanged
- No dirty tracking

---

## Performance Improvement Paths

### Path 1: Batcher Caching (Low Effort, High Impact)

**Concept:** For static scenes, sort once and reuse the result.

**Implementation:**
- Add dirty flag to DrawBatcher
- Only re-sort when objects added/removed/materials changed
- Cache sorted batches and instance groups

**Expected Gain:** Save 6ms+ at 32k objects (static scenes only)

**Limitations:** Only helps when scene is static

### Path 2: Dirty Tracking for Sync (Medium Effort, Medium Impact)

**Concept:** Only sync transforms that actually changed.

**Implementation:**
- Add dirty flags to scene entities
- RenderSceneModule only updates dirty proxies
- Clear dirty flag after sync

**Expected Gain:** Save 2ms+ at 32k objects (mostly static scenes)

**Limitations:** Less benefit when many objects move

### Path 3: Spatial Culling - Octree/BVH (Medium Effort, High Impact)

**Concept:** Hierarchical spatial structure for O(log n) culling.

**Implementation:**
- Build octree/BVH from object bounds
- Cull entire tree nodes against frustum
- Only test individual objects in visible leaf nodes

**Expected Gain:**
- Current 32k: 3.17ms → ~0.5ms
- Enables 100k+ objects

**Considerations:**
- Tree needs updating when objects move
- Static vs dynamic object separation helps

### Path 4: SIMD Frustum Culling (Low-Medium Effort, Medium Impact)

**Concept:** Test multiple objects simultaneously using SIMD.

**Implementation:**
- SOA (Structure of Arrays) for object bounds
- Process 4-8 objects per SIMD operation
- Use AVX/SSE intrinsics

**Expected Gain:** 2-4x speedup on culling

### Path 5: Multi-threaded Culling/Batching (Medium Effort, High Impact)

**Concept:** Parallelize CPU work across cores.

**Implementation:**
- Divide objects into chunks
- Cull chunks in parallel (job system)
- Merge results

**Expected Gain:** 2-4x speedup (scales with core count)

**Considerations:** Requires thread-safe data structures

### Path 6: GPU-Driven Rendering (High Effort, Very High Impact)

**Concept:** Move culling and draw call generation to GPU.

**Implementation:**
- Compute shader for frustum/occlusion culling
- Indirect draw calls (DrawIndexedIndirect)
- GPU builds draw commands directly

**Expected Gain:** 1,000,000+ objects possible

**Components Needed:**
- Object bounds buffer (GPU)
- Visibility compute shader
- Indirect argument buffer
- Multi-draw indirect support

**This is the industry standard for massive object counts.**

---

## Realistic Expectations

| Approach | Max Objects @ 60 FPS | Effort |
|----------|---------------------|--------|
| Current (optimized) | ~28,000 | Done |
| + Batcher caching | ~50,000 | Low |
| + Spatial culling | ~100,000 | Medium |
| + Multi-threading | ~150,000 | Medium |
| + GPU-driven | 1,000,000+ | High |

---

## Profiler Integration

The render system is instrumented with `SProfiler` markers:

**RenderSystem.bf:**
- `Render.BeginFrame`, `Render.BuildGraph`, `Render.Execute`, `Render.EndFrame`

**DepthPrepassFeature.bf:**
- `DepthPrepass.AddPasses`, `Visibility.Resolve`, `Batcher.Build`, `PrepareUniforms`
- `DepthPrepass.Execute`, `InstancedDraw`, `NonInstancedDraw`, `SkinnedMeshes`

**ForwardOpaqueFeature.bf:**
- `ForwardOpaque.AddPasses`, `UpdateLighting`, `AddShadowPasses`, `PrepareObjectUniforms`
- `ForwardOpaque.Execute`, `InstancedDraw`, `NonInstancedDraw`, `SkinnedMeshes`

**RenderGraph.bf:**
- Per-pass timing using pass names

Press **P** in samples to print profiler breakdown.

---

## Appendix: Historical Comparison

### Before Any Optimization (8k objects)

| Mode | Frame Time | FPS |
|------|-----------|-----|
| Debug | 19.3ms | 52 |
| Release | 17.3ms | 58 |

### After Uniform Skip Optimization (8k objects)

| Mode | Frame Time | FPS | Improvement |
|------|-----------|-----|-------------|
| Debug | 13.0ms | 77 | +48% |
| Release | 6.8ms | 147 | +153% |

### Scaling Achievement

- **Before:** 8k objects maxed out at 58 FPS
- **After:** 32k objects at 45 FPS (4x more objects)
- **GPU utilization:** Only 4% of frame time - massive headroom remains
