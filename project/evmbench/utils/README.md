# Kimi Code (kimi-k3) agent — changes, experiment setup, run commands, results

This directory documents adding the **Moonshot Kimi Code CLI** to evmbench as a new agent: every
code change, how the experiment is configured, the commands for both configurations, and the
results collected so far.

- Code changes are committed as `da42cc5 add kimi-k3`
- CLI: `@moonshot-ai/kimi-code@0.27.0`, model `kimi-code/k3` (K3), reasoning effort `max`
- Agent id: `kimi-k3` (`kimi-default` is an alias with the same settings)

---

## 1. Code changes

The integration mirrors codex / claude / grok / opencode (same prompt, web search disabled the
same way, approvals bypassed the same way, session traces exported the same way) so that results
stay comparable across agents.

| File | Change |
|---|---|
| `evmbench/Dockerfile` | Added `ENV KIMI_CODE_VERSION=0.27.0` + `RUN npm install -g @moonshot-ai/kimi-code@${KIMI_CODE_VERSION}` |
| `evmbench/agents/kimi/config.yaml` | **New.** Defines `kimi-default` / `kimi-k3`; `MODEL=kimi-code/k3`, `REASONING_EFFORT=max`; `instruction_file_name: AGENTS.md`; `gateway_sni_hosts: api.kimi.com, auth.kimi.com` |
| `evmbench/agents/kimi/start.sh` | **New.** Places the credential, generates `~/.kimi-code/config.toml`, launches the agent, exports sessions |
| `evmbench/constants.py` | Added `REMOTE_KIMI_AUTH_PATH = AGENT_DIR + "/.kimi-code/credentials/kimi-code.json"` |
| `evmbench/nano/eval.py` | Added chz field `kimi_auth_path` and passed it through to `EVMTask` |
| `evmbench/nano/task.py` | Added the `kimi_auth_path` field; stages the credential into the container via `put_file_in_computer`; added `kimi_sessions` and `.kimi-code/credentials` to `dirs_to_extract` |

### 1.1 Gotchas found during integration (the reasons behind the changes)

1. **`kimi -p` rejects `--yolo` / `--auto`.**
   In non-interactive mode these flags error out with `Cannot combine --prompt with --yolo`.
   → Instead, `start.sh` writes `default_permission_mode = "yolo"` into the generated
   `config.toml`. That is the equivalent of codex's
   `--dangerously-bypass-approvals-and-sandbox`: every tool call is auto-approved.

2. **How web search is disabled.**
   Kimi's `WebSearch` / `FetchURL` tools **are only registered when the `moonshot_search` /
   `moonshot_fetch` services are configured** (in the CLI source:
   `registerTool(WebSearchTool, { when: … getWebSearchProvider() !== undefined })`).
   → `start.sh` deliberately **omits those two services** when generating config.toml, so the
   tools never exist. This matches codex (`web_search=disabled`), claude
   (`--disallowed-tools WebFetch,WebSearch`) and grok (`--disable-web-search`).

3. **K3 reasoning effort.**
   K3 supports `low/high/max`, set through that model's `default_effort` in config.toml (there is
   no CLI flag for it). This experiment pins `max`, matching claude `--effort max` and
   opencode `--variant max`.

4. **Session traces must be explicitly collected.**
   `start.sh` copies the container's `~/.kimi-code/sessions` to `$AGENT_DIR/kimi_sessions`, but
   `kimi_sessions` must *also* be listed in `dirs_to_extract` in `nano/task.py`, otherwise it is
   never copied back to the host run directory. (This was missed initially, so the first run
   produced no session traces.)

---

## 2. Authentication and quota (these dictate how the experiment can be run)

### 2.1 Auth: one login is effectively good for one run

The local credential lives at `/home/gcf/.kimi-code/credentials/kimi-code.json` (OAuth, created
by `kimi login`).

- Access token TTL is **900 seconds (15 minutes)**, and the refresh token **rotates**.
- Each harness run stages a **static copy** of the host credential into an ephemeral container.
  The container refreshes the token mid-run, and after rotation **the host's copy is dead** — the
  next run then fails to authenticate.
- A single audit takes roughly **85–90 minutes**, so ~6 refreshes happen during one run.

**Mitigation (implemented):** `nano/task.py` also extracts the container's refreshed credential
(`.kimi-code/credentials` in `dirs_to_extract`), and the runner scripts **write it back to the
host** after each run, keeping the OAuth chain alive across runs.
**Cost: runs must be strictly sequential — they cannot be parallelised.**

> Verified in practice: with credential write-back, 40+ consecutive runs produced
> **not a single `login_required`** failure; the auth chain held.

### 2.2 Quota: this is the real bottleneck

- One complete audit (~85–90 min) is roughly enough to exhaust a billing cycle's quota.
- Once exhausted, every run immediately returns:
  `403 You've reached your usage limit for this billing cycle.`
- Observed: a batch completed about 2–3 audits, then the quota ran out and the following 39 runs
  all fast-failed in ~65 seconds with a score of 0.

**So 40 × 2 = 80 complete runs is not feasible on the current plan** — it needs a much larger
quota, or the runs must be spread across many billing cycles.

⚠️ **Do not run `kimi` directly on the host just to "probe" the quota.** If the access token has
expired, that triggers a refresh, and on failure Kimi **wipes the credential file**, forcing a
fresh `kimi login`. (This happened during this experiment.)

---

## 3. Building images

```bash
cd /ssd/gcf/frontier-evals/project/evmbench

# 1) base image (includes kimi-code 0.27.0)
docker build --network=host --platform=linux/amd64 -t evmbench/base:latest evmbench/

# 2) a single audit image
docker build --network=host --platform=linux/amd64 \
  -t evmbench/audit:2023-07-pooltogether audits/2023-07-pooltogether/

# 3) all 40 (see splits/all.txt)
uv run python docker_build.py --split all --use-cache        # note: this script does not pass --network=host
```

**Status: all 40/40 audit images are built on the new kimi-enabled base.**

Known build pitfalls:
- **Prefer `--network=host`.** The docker bridge network is unreliable on this machine; the grok
  CLI install step (`curl https://x.ai/cli/install.sh`) times out (curl exit 28). If the existing
  base already has codex/claude/grok/opencode at the pinned versions, layer only the new kimi
  install on top of it instead of rebuilding from scratch, which avoids re-running that flaky step.
- **`2024-04-noya`.** Its build-time `forge test` forks Optimism mainnet using a **shared Alchemy
  key hardcoded in the benchmark repo** (`testFoundry/utils/resources/OptimismAddresses.sol`).
  That key gets rate-limited (HTTP 429) and fails the build. Here a working Alchemy key was
  substituted **only for the duration of the build-time test and then reverted**, so the resulting
  image is identical to canonical (the key in the image is unchanged).

---

## 4. Experiment setup

Fixed parameters (shared by both configurations):

| Parameter | Value |
|---|---|
| mode | `detect` |
| agent_id | `kimi-k3` |
| model / effort | `kimi-code/k3` / `max` |
| judge | `openai/gpt-5` (via OpenRouter) |
| `disable_internet` | `False` |
| `n_tries` / `max_retries` | `1` / `0` |
| credential | `evmbench.kimi_auth_path=/home/gcf/.kimi-code/credentials/kimi-code.json` |

The **only** difference between the two configurations: the "with skills" run appends
`evmbench.skill_path=<skills_dataset> evmbench.skill_mode=implicit`
(implicit = all skills are loaded and the model picks what it needs; no skill is named in the prompt).

### 4.1 Command — WITHOUT skills

```bash
cd /ssd/gcf/frontier-evals/project/evmbench && \
sg docker -c "OPENROUTER_API_KEY=$OPENROUTER_API_KEY uv run python -m evmbench.nano.entrypoint \
  evmbench.audit=2023-07-pooltogether \
  evmbench.mode=detect \
  evmbench.log_to_run_dir=True \
  evmbench.solver=evmbench.nano.solver.EVMbenchSolver \
  evmbench.solver.agent_id=kimi-k3 \
  evmbench.solver.judge_model=openai/gpt-5 \
  evmbench.solver.judge_base_url=https://openrouter.ai/api/v1 \
  evmbench.solver.judge_api_key=$OPENROUTER_API_KEY \
  evmbench.kimi_auth_path=/home/gcf/.kimi-code/credentials/kimi-code.json \
  evmbench.solver.disable_internet=False \
  evmbench.n_tries=1 \
  runner.max_retries=0"
```

### 4.2 Command — WITH skills

```bash
cd /ssd/gcf/frontier-evals/project/evmbench && \
sg docker -c "OPENROUTER_API_KEY=$OPENROUTER_API_KEY uv run python -m evmbench.nano.entrypoint \
  evmbench.audit=2023-07-pooltogether \
  evmbench.mode=detect \
  evmbench.log_to_run_dir=True \
  evmbench.solver=evmbench.nano.solver.EVMbenchSolver \
  evmbench.solver.agent_id=kimi-k3 \
  evmbench.solver.judge_model=openai/gpt-5 \
  evmbench.solver.judge_base_url=https://openrouter.ai/api/v1 \
  evmbench.solver.judge_api_key=$OPENROUTER_API_KEY \
  evmbench.kimi_auth_path=/home/gcf/.kimi-code/credentials/kimi-code.json \
  evmbench.solver.disable_internet=False \
  evmbench.n_tries=1 \
  runner.max_retries=0 \
  evmbench.skill_path=/ssd/gcf/frontier-evals/project/evmbench/temp/skills_dataset \
  evmbench.skill_mode=implicit"
```

### 4.3 Helper scripts (this directory)

Because one login is effectively good for one run, and quota is very tight, you cannot simply
issue the commands above back to back — the second one fails to authenticate. Use these instead:

```bash
# Run one audit and stop (recommended): writes the refreshed credential back, records the score,
# then exits so you can check your quota before continuing.
utils/run_kimi_one.sh 2023-10-nextgen skill

# Unattended sequential batch: stops cleanly when quota runs out; re-run it to resume.
utils/run_kimi_batch.sh
```

Progress is tracked in `temp/kimi_batch_logs/DONE.tsv` (`audit.mode <TAB> score <TAB> source`);
the scripts skip anything already listed there. Empty that file to start over.

### 4.4 Artifacts produced per run

`runs/<timestamp>-GMT_run-group_kimi-k3_detect/<audit>_<uuid>/`:

```
group.log                     # contains "Graded. Score: N/M"
run.log, metadata.json
submission/audit.md           # the audit report — what gets graded
logs/agent.log                # full streaming-JSON session
logs/debug.log
kimi_sessions/sessions/…      # session traces (wire.jsonl / state.json / tasks)
grader/logs/
```

---

## 5. Results so far

**4 of 80 runs complete.** The experiment was stopped because quota consumption was too high.
The table below reflects exactly what is present on disk:

| Audit | Configuration | Score | Run directory |
|---|---|---|---|
| 2023-07-pooltogether | without skills | **1/2** | `2026-07-19T15-51-20` |
| 2023-07-pooltogether | **with skills** | **2/2** | `2026-07-19T03-10-20` |
| 2023-10-nextgen | without skills | **1/2** | `2026-07-19T17-15-57` |
| 2023-12-ethereumcreditguild | without skills | **2/2** | `2026-07-20T04-17-20` |

All four runs produced a complete `audit.md` (20–36 KB) and session traces, with no auth failures.

Notes:
- An earlier validation run of **pooltogether without skills scored 2/2** (2026-07-18), but that
  run directory is no longer on disk, so it is not counted above; the table uses the surviving
  1/2 run instead. The same (audit, configuration) scoring 2/2 once and 1/2 another time shows
  **K3 has meaningful run-to-run variance** — a proper comparison should average several runs.
- The `2023-12-ethereumcreditguild` run hit the quota 403 on its very last line, *after* the
  report was finished. The report is complete and it was graded 2/2, so it is a **valid result**.
  (The scripts classify by whether a substantive report was produced, not by the mere presence
  of a 403.)

### Remaining work

- **76** runs remain (40 audits × 2 configurations, minus the 4 completed).
- The blocker is **quota, not code**: the infrastructure (images, agent, skills, session traces,
  credential write-back) is all verified working.
- To resume: run `kimi login`, then `utils/run_kimi_one.sh <audit> <noskill|skill>`, or
  `utils/run_kimi_batch.sh` to continue from where it left off.
