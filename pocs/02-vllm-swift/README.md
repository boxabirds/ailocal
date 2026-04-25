# POC 2 — vllm-swift + Qwen3.6-27B

**Result: ❌ BLOCKED at runtime — missing GDN Metal kernels.**

The Swift/Metal bridge builds and loads cleanly, vllm-swift's plugin registers, the model file is found, but inference fails at the first **gated-delta-network (GDN) attention op** that Qwen3.6-27B's hybrid architecture requires:

```
MLX/ErrorHandler.swift:345: Fatal error:
[metal::Device] Unable to load function gated_delta_step_fused_bfloat16_128_128_16_48
```

This is a **known limitation** acknowledged in the upstream `install.sh`:
> `WARNING: Some models (GDN/TurboFlash) may fail.`

The `.metal` source files for these kernels exist in the `mlx-swift-lm` Swift dependency under `Source/Cmlx/mlx-generated/metal/gated_delta.metal`, but the standard `swift build` path doesn't compile them into a metallib. The published v0.2.1 was tested on Qwen3-4B (a non-GDN model); Qwen3.6-27B is hybrid GDN and trips this case.

## What we proved
- **vllm-swift v0.2.1 source build works on macOS 26 + M5 Max** (Swift bridge compiles in 97s).
- **Their brew formula does NOT work on macOS 26** — no `arm64_tahoe` bottle and the source-build path inside brew hits a `sandbox_apply: Operation not permitted` because Swift's package manager re-invokes `sandbox-exec` independently of brew's sandbox toggle. From-source via `./scripts/install.sh` works.
- **vllm 0.19.1 builds on Mac via pip**: builds to `vllm-0.19.1-cp313-cp313-macosx_26_0_arm64.whl`. **uv is too strict** (refuses `nvidia-cudnn-frontend` on Mac); pip's looser resolver succeeds.
- **The vllm-swift plugin registers correctly** — boot log: `Platform plugin swift is activated`.

## Setup (uv-based, replaces upstream pip+venv)

```bash
cd pocs/02-vllm-swift
git clone --depth 1 https://github.com/TheTom/vllm-swift.git src
./install_uv.sh   # swift build + uv venv
# then bootstrap pip into the uv venv (uv venv excludes pip by default)
.venv/bin/python -m ensurepip --upgrade
CFLAGS="-Wno-parentheses" CXXFLAGS="-Wno-parentheses" .venv/bin/pip install "vllm>=0.19.0"
```

## What would fix it

To support Qwen3.6-27B on vllm-swift, one of:
1. Upstream needs to compile the GDN Metal kernels from `mlx-swift-lm`'s `.metal` sources into `mlx.metallib` during build (currently only Python's `mlx` metallib is copied, which lacks these).
2. Manual workaround: `xcrun metal -c gated_delta.metal -o gated_delta.air` for each required kernel, `xcrun metallib *.air -o mlx.metallib` — significant Metal-shader-toolchain work, out of scope for this POC.
3. Wait for upstream — TheTom/vllm-swift is shipping daily; v0.2.1 is from today.

## Verdict for the recipe

**vllm-swift is not currently a viable path for Qwen3.6-27B on Mac.** Re-evaluate when upstream fixes the GDN kernel compilation. The DFlash speculative-decoding angle (which was the original interest in vllm-swift) couldn't even be tested because the model never loads.

**Smaller dense Qwen3 variants (e.g., Qwen3-4B-4bit) likely work today** — they don't use GDN — but that's not the user's target model.
