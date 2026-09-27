# Next steps: Laya add-in + competitive response

_Written 2026-09-27._

## Positioning

**Rulekit stays deterministic by default. Semantic (model-judged) rules become an optional, local add-in backed by Laya.**

That puts rulekit against [abide](https://github.com/coldteadotai/abide), which judges every rule with a hosted model (Jev), as "the same idea, but local, free, no login, and pre-write".

| | rulekit today | rulekit + Laya | abide |
|---|---|---|---|
| Judgement | glob / regex / Ruby detector | + local probability (`laya:` rules) | hosted probability (Jev) |
| Timing | pre-write deny + post-write sweep | same | post-edit repair + end-of-turn diff |
| Cost / network | free, offline | free, offline (local server) | ~$0.00005/check, login required |
| Rule authoring | hand-written YAML | hand-written YAML | compiled from CLAUDE.md / AGENTS.md |
| Read side | search nudges | same | none at runtime |
| Agents | Claude Code | Claude Code | Claude Code, Codex, OpenCode |

## 1. Laya local setup

State as of 2026-09-27:

- [x] Repo cloned to `~/Development/laya`
- [x] `.venv` on Python **3.14.7**, `pip install -e ".[serve]"` succeeded: torch 2.14.0, transformers 5.17.0, MPS available. The 3.13 classifier ceiling didn't bite.
- [x] `~/Development/laya/serve-local.sh` (git-excluded) starts `laya-serve` with safe local defaults:
  - `LAYA_HOST=127.0.0.1`: `laya-serve` defaults to **`0.0.0.0`**
  - `LAYA_MODELS=english`: default preloads **all three** checkpoints
  - `LAYA_DEVICE=mps`
- [ ] **Finish the model download** (~1.7GB; interrupted on a slow connection). First run of `serve-local.sh` resumes it.
- [ ] Smoke test: `curl -s localhost:8000/health`, then a `noul` question on **`POST /v1/systemone`**. That's the packaged `laya-serve` route; `/predict` belongs only to `examples/server.py`.
- [ ] **Benchmark MPS latency** with the `curl -w '%{time_total}'` snippet in README → "Semantic rules with Laya". Laya's own server notes say CPU calls take "hundreds of milliseconds to seconds". Hook timeout is 5s; target < 300ms p95.
- [ ] If slow: try `laya-mlx` (claims 7–14ms on Apple Silicon, but has no server, so we'd need a small FastAPI wrapper that speaks `/v1/systemone`)

## 2. Fine-tune a code-rules checkpoint (local, RTX 5070 12GB)

**Why:** Base checkpoints are near chance zero-shot (0.36 vs 0.318 random on Laya's typed-decisions benchmark). Fine-tuned is 0.766, beating TypeSafe Jev's 0.727. Laya's own advice: *"Treat Laya as a fast base to specialise, not as a zero-shot decision engine."* A code-specific checkpoint is also the edge over abide, which uses Jev as-is.

```
Mac                          5070 box (Linux/WSL2)              Hugging Face
─────────────────────────    ───────────────────────────────    ─────────────────────
2a zero-shot baseline  ─┐
2b build dataset  ──────┼──► 2c smoke run → full fine-tune
                        │       + calibrate ─────────────────► rhys117/laya-rulekit
2d re-benchmark  ◄──────┴─────────────────────────────────────── (server loads it)
```

### 2a. Zero-shot baseline (Mac)

- [ ] Fixture set: should-fire / should-pass code snippets per candidate semantic rule
- [ ] Run against stock `laya` → precision/recall per threshold. Expect poor; this is the number to beat.

### 2b. Build the dataset

Sources of labelled `(state, question) → answer`:

1. Rails preset `test.sh` fixtures: already labelled fire/pass
2. Deterministic rules replayed over real git history (Rails repos): cheap labels at volume
3. Claude as teacher for cases regex can't decide (the same pattern Laya's benchmark uses: teacher self-agreement is the ceiling)

- [ ] Start small: a few thousand items for a first pass (their run was ~30k)
- [ ] **Hold out a separate eval split.** The notebook's calibration samples come from its training items; don't claim gains on those.

### 2c. Adapt the notebook for one 5070

Source: `~/Development/laya/notebooks/laya_finetune_typed_decisions_2xT4_kaggle.ipynb`

| Setting | Notebook (2×T4 DDP) | 5070 (single GPU) |
|---|---|---|
| Parallelism | `DistributedDataParallel` / torchrun | remove; plain single-process loop |
| `MICRO_BATCH` | 8 | 8 (fallback 4) |
| `GRAD_ACCUM` | 4 (→ effective 64) | 8 (→ effective 64); 16 if micro = 4 |
| Precision | fp16 autocast + `GradScaler` | bf16 autocast, drop `GradScaler` (optional) |
| Gradient checkpointing | on | keep on |
| `OUTPUT_DIR` / model paths | `/kaggle/working/...` | local paths |
| `NEW_REPO` | `convaiinnovations/laya-typed-decisions` | `rhys117/laya-rulekit` |
| Unchanged | `EPOCHS=4`, `GROUP_SIZE=4`, `LR_ENCODER=2.5e-5`, `LR_HEAD=1e-4`, `SIGMA 0.4→0.1` | |

Memory estimate (421M params): weights 1.7GB + grads 1.7GB + AdamW 3.4GB ≈ 6.8GB fixed, plus activations → **~9–11GB, tight**. Fallback: `laya-multilingual` (322M, ~5.2GB fixed).

Environment gotchas:

```bash
# Blackwell (sm_120) needs CUDA 12.8 wheels, torch >= 2.7
pip install torch --index-url https://download.pytorch.org/whl/cu128
```

- Linux or WSL2, not native Windows
- `no kernel image is available` = wrong torch wheel

- [ ] Smoke run: 50 steps, watch peak memory in `nvidia-smi`
- [ ] Full run (expect roughly 2×T4 speed or better; theirs was 4–5h for 30k questions × 4 epochs)
- [ ] Calibration: one temperature per type (`choice`/`score`/`noul`); notebook strips inherited `temperature_by_options`
- [ ] Push to `rhys117/laya-rulekit`

### 2d. Re-benchmark (Mac)

- [ ] Point the local server at the new checkpoint, rerun 2a's held-out eval
- [ ] **Gate for step 3:** meaningfully above baseline at a usable threshold, and latency still < 300ms p95

## 3. Engine support for `laya:` rules

**Built on `feat/laya-rules`** (ahead of step 2, so the fine-tune has somewhere to plug in). Tested only against a fake server so far.

- [x] `plugins/rulekit/lib/laya_client.rb`: stdlib `Net::HTTP`, `POST /v1/systemone`, `noul` question, `open_timeout` 0.2s, `read_timeout` 2.0s (`LAYA_TIMEOUT`), `LAYA_URL`, `LAYA_API_KEY`; returns `nil` on any error
- [x] `RulesRunner#apply_write_rules`: detector file > `laya:` block > fire. `pattern` still prefilters before any request
- [x] Server-down marker `tmp/.claude-advisory/<session>/laya-down` with a **60s TTL**, so a server started mid-session is picked up
- [x] Post-write sweep covered for free (same `apply_write_rules`)
- [x] `/rules-test`: `laya:` rules SKIPPED, not failed, when the server is unreachable
- [x] README section "Semantic rules with Laya (optional)", guidance to keep `laya:` rules to `warn`
- [x] `plugins/rulekit/test/laya.sh` + `fake_laya_server.rb`: 12 tests (fire, silent, prefilter, detector precedence, fail open, down-marker skip). Rails preset still 71/71.

Deviations from the original plan:

| Plan | Built | Why |
|---|---|---|
| `POST /predict` | `POST /v1/systemone` | the route the packaged `laya-serve` exposes |
| state = on-disk file + new content | `File: <path>` + new content, 2000 chars | 512-token window; the whole file would push the edit out |
| read timeout ~0.5s | 2.0s | Laya's MPS/CPU latency is unknown; tighten after the benchmark |

Still to do:

- [ ] Run `test/laya.sh`-style cases against the **real** server once the model is down
- [ ] Tune `LAYA_TIMEOUT` default from the benchmark
- [ ] One commented-out example `laya:` rule in the Rails preset (like the Sorbet rule)
- [ ] Only mark the server down on connection errors/timeouts/5xx. Today a 4xx (e.g. 422 on a malformed question) also marks it down for 60s, which silences every `laya:` rule
- [ ] Batch all `laya:` rules for one file into a single request (`questions` takes many keys) if several rules share a glob
- [ ] Read-side (`read.yml`) `laya:` support: not built, probably not needed
- [ ] Reuse the 2a/2d benchmark as a regression check for `laya:` rules

## 4. Ideas taken from abide

| Idea | Rulekit version | Priority |
|---|---|---|
| Compile rules from existing docs | `/rules-compile`: agent drafts `write.yml` entries from `CLAUDE.md`, each quoting the source line | High |
| End-of-turn whole-diff check | `Stop` hook that runs turn-scoped rules over the full diff (catches cross-file issues per-edit checks miss) | Medium |
| Rule health reporting | `/rules-report`: which rules fired, which never fired (sentinels + a log) | Medium |
| Calibration against git history | Replay rules over recent commits to find noisy/dead rules | Low |
| Multi-agent support | Codex / OpenCode hook adapters | Low |

## 5. Docs

- [ ] Add abide to README "Prior art" alongside Hookify, with the deterministic-vs-probabilistic distinction.
- [x] Document the Laya add-in as optional; no-op when the server isn't running.

## Open questions

- Is Laya (trained on support/triage text) any good at judging **code**? Step 2 answers this: zero-shot is expected to be near chance; fine-tuning is the bet.
- ~~Python 3.14 vs 3.12 for the Laya venv~~: 3.14 works on the Mac. The 5070 box still needs its own env (CUDA 12.8 torch).
