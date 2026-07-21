#!/bin/bash
# Run EXACTLY ONE kimi-k3 audit, then exit — for gated execution (run one, check quota, run next).
#
#   usage: utils/run_kimi_one.sh <audit_id> <noskill|skill>
#   e.g.   utils/run_kimi_one.sh 2023-10-nextgen skill
#
# On success: writes the container's refreshed OAuth credential back to the host (keeping the
# auth chain alive for the next run) and appends the result to DONE.tsv.
# On a run that produced no report: records nothing and exits 3 so the caller stops.
set -u
ROOT=/ssd/gcf/frontier-evals/project/evmbench
HOST_CRED=/home/gcf/.kimi-code/credentials/kimi-code.json
SKILLS="$ROOT/temp/skills_dataset"
LOGDIR="$ROOT/temp/kimi_batch_logs"; mkdir -p "$LOGDIR"
DONE="$LOGDIR/DONE.tsv"; touch "$DONE"

audit="${1:?audit id required}"; mode="${2:?mode required: noskill|skill}"
tag="${audit}.${mode}"
log="$LOGDIR/${tag}.log"
skill_args=""; [ "$mode" = "skill" ] && skill_args="evmbench.skill_path=$SKILLS evmbench.skill_mode=implicit"

cred_ok() { python3 -c "import json,sys; d=json.load(open('$1')); sys.exit(0 if d.get('access_token') and d.get('refresh_token') else 1)" 2>/dev/null; }
# NOTE: use awk, not `grep -qxF <(...)`. `grep` here is ugrep, where that combination silently
# fails to match — which would silently re-run completed audits and burn scarce quota.
is_done() { awk -F'\t' -v t="$1" '$1==t{f=1} END{exit !f}' "$DONE"; }

if is_done "$tag"; then echo "ALREADY_DONE $tag"; exit 0; fi
if ! cred_ok "$HOST_CRED"; then echo "RESULT $tag ABORT host-credential-invalid (run: kimi login)"; exit 2; fi

echo "=== RUN $tag ($(date -u '+%F %H:%M:%SZ')) ==="
( cd "$ROOT" && sg docker -c "OPENROUTER_API_KEY=$OPENROUTER_API_KEY uv run python -m evmbench.nano.entrypoint \
    evmbench.audit=$audit evmbench.mode=detect evmbench.log_to_run_dir=True \
    evmbench.solver=evmbench.nano.solver.EVMbenchSolver evmbench.solver.agent_id=kimi-k3 \
    evmbench.solver.judge_model=openai/gpt-5 evmbench.solver.judge_base_url=https://openrouter.ai/api/v1 \
    evmbench.solver.judge_api_key=$OPENROUTER_API_KEY \
    evmbench.kimi_auth_path=$HOST_CRED evmbench.solver.disable_internet=False \
    evmbench.n_tries=1 runner.max_retries=0 $skill_args" ) > "$log" 2>&1
rc=$?

rundir=$(grep -aoE "runs/[^ ]*kimi-k3_detect/${audit}_[a-f0-9-]+" "$log" | head -1)
agentlog="$ROOT/$rundir/logs/agent.log"
amd=$(stat -c%s "$ROOT/$rundir/submission/audit.md" 2>/dev/null || echo 0)
score=$(grep -aoE "Graded. Score: [0-9]+/[0-9]+" "$ROOT/$rundir/../group.log" 2>/dev/null | tail -1)

# Classify by WORK PRODUCED, not merely by the presence of a quota error. kimi often burns the
# last of the quota right as it finishes, so the 403 lands on the final line AFTER a complete,
# gradeable report. Treating that as failure silently discards a good run (it once threw away a
# 2/2). Only a run with no real report is a true failure.
quota_hit=0
grep -aqiE "usage limit for this billing cycle|login_required|Cannot combine --prompt" "$agentlog" "$log" 2>/dev/null && quota_hit=1
if [ "${amd:-0}" -lt 2000 ]; then
    why=$(grep -aoiE "usage limit for this billing cycle|login_required|Cannot combine --prompt" "$agentlog" "$log" 2>/dev/null | head -1)
    echo "RESULT $tag STOP no-report (audit.md=${amd}B, rc=$rc)${why:+ : $why}"; exit 3
fi

newcred="$ROOT/$rundir/credentials/kimi-code.json"
if [ -n "$rundir" ] && [ -f "$newcred" ] && cred_ok "$newcred"; then
    cp "$newcred" "$HOST_CRED"; rm -rf "$ROOT/$rundir/credentials"   # don't leave tokens in the run dir
    printf '%s\t%s\t%s\n' "$tag" "$score" "$(date -u +%FT%H:%MZ)" >> "$DONE"
    msg="RESULT $tag OK $score ; writeback=ok ; audit.md=${amd}B ; done=$(wc -l < "$DONE")/80"
    [ "$quota_hit" = 1 ] && msg="$msg ; WARNING: quota limit hit at end of run — CHECK QUOTA before the next one"
    echo "$msg"
else
    echo "RESULT $tag NOCRED $score ; no refreshed credential -> host cred NOT updated (chain would break)"; exit 4
fi
