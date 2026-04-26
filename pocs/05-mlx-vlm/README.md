# POC 5 — mlx-vlm + Qwen3.6-27B (vision-enabled)

**Result: ✅ vision works on `unsloth/Qwen3.6-27B-MLX-8bit` against [`Blaizzy/mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) v0.4.4.** Same on-disk model as POC 1.

## Why this exists

POC 1 (mlx-lm) won the bench but its server is text-only:

```
{"error": "Only 'text' content type is supported."}
```

The model itself is multimodal — its `config.json` has `architectures: ["Qwen3_5ForConditionalGeneration"]`, populated `vision_config`, and `image_token_id`/`video_token_id` set; the on-disk weights are **1367 language-model + 333 vision-tower** tensors. mlx-lm just ignores the vision side. mlx-vlm loads it.

## Setup

```bash
cd pocs/05-mlx-vlm
uv venv --python 3.12 .venv
source .venv/bin/activate
uv pip install mlx-vlm torch torchvision
./serve.sh    # listens on 127.0.0.1:8080 (same as POC 1; only one at a time)
```

The torch + torchvision dependency is **not optional** — transformers' `Qwen3VLVideoProcessor` hard-imports them even if you never send a video. Adds ~600 MB to the venv.

## Verified locally on 2026-04-26

Spawned the server, sent a 256×96 PNG containing a freshly-generated random base64 token (8 bytes, urlsafe, generated immediately before the image was rendered — model could not have predicted it from text context). Three controlled tests:

| Test | Setup | Expected | Got |
|---|---|---|---|
| 1 | image with random token `7ARO-npcq8o`, "output only the exact text" | `7ARO-npcq8o` | ✅ exact match |
| 2 | **no image**, same prompt | refusal / "no image" | `[Image 1]` (correctly noted absence) |
| 3 | blue background image, "what color?" | `blue` | ✅ correct |

Test 1 is decisive: the model could not have hallucinated an unguessable random token.

Bench numbers from a single warm probe:
- prompt prefill: 22.7 tok/s
- generation: 14.6 tok/s (identical to mlx-lm — vision tower runs once at prefill)
- peak resident memory: **35.1 GB** (33 GB language model + ~2 GB vision tower at this image size)

## Why we don't replace POC 1 by default

- mlx-lm 0.31.3 is more mature than mlx-vlm 0.4.4.
- 600 MB of torch deps is wasted weight if the user only does text.
- POC 1's bench numbers are still the canonical baseline; this POC is the opt-in vision path.

`install.sh --with-vision` swaps this in.

## ⚠ Known issue worth re-verifying after upgrades

[Blaizzy/mlx-vlm#1057](https://github.com/Blaizzy/mlx-vlm/issues/1057) (filed 2026-04-24, **unmerged** at the time of this POC) describes a sanitize bug where Qwen3.6 ViT tensors are **silently dropped** in the `qwen3_5_moe` model class — the server returns 200 with plausible-sounding text, but the vision tower never loaded.

The bug was filed against a **35B-A3B MoE** variant. The empirical 3-test probe above on the **dense 27B** checkpoint passed cleanly, so this checkpoint is unaffected on v0.4.4. But: if you upgrade mlx-vlm or switch to a different Qwen3.6 variant (35B-A3B, or any `qwen3_5_moe` checkpoint), **re-run the random-token verification** before trusting the output. Plausible text is the failure mode, not an obvious crash.
