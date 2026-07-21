#!/bin/bash
# Sequential, RESUMABLE kimi-k3 batch over all audits in splits/all.txt, WITHOUT then WITH skills.
#
#   usage: utils/run_kimi_batch.sh        # resumes; skips anything already in DONE.tsv
#   reset: : > temp/kimi_batch_logs/DONE.tsv
#
# WHY SEQUENTIAL (cannot be parallelised): kimi's OAuth access token has a 15-min TTL and the
# refresh token rotates. Each harness run stages a *static copy* of the host credential into an
# ephemeral container which refreshes mid-run — invalidating the host copy. Two concurrent runs
# would fight over the same token and fail. So: one at a time, and after each run copy the
# container's refreshed credential (extracted to <run_dir>/credentials/) back to the host.
#
# WHY RESUMABLE: quota only covers ~1 audit per billing cycle, after which every run returns
# 403 "usage limit for this billing cycle". This stops on the first such run (never churning
# 0-score garbage) and records completed runs in DONE.tsv, so re-running later continues.
#
# NOTE: given the quota reality, utils/run_kimi_one.sh (one run, then stop for a manual quota
# check) is usually the better tool. This script is the unattended variant.
set -u
ROOT=/ssd/gcf/frontier-evals/project/evmbench
LOGDIR="$ROOT/temp/kimi_batch_logs"; mkdir -p "$LOGDIR"
DONE="$LOGDIR/DONE.tsv"; touch "$DONE"
ONE="$ROOT/utils/run_kimi_one.sh"

SKIP=""   # space-separated audit ids to exclude, if ever needed
mapfile -t ALL < <(grep -v '^[[:space:]]*$' "$ROOT/splits/all.txt")
AUDITS=(); for a in "${ALL[@]}"; do case " $SKIP " in *" $a "*) continue;; esac; AUDITS+=("$a"); done

TOTAL=$(( ${#AUDITS[@]} * 2 ))
echo "### RESUMABLE BATCH: $(wc -l < "$DONE")/$TOTAL already complete ($(date -u '+%F %H:%M:%SZ')) ###"
for mode in noskill skill; do
    echo "### PHASE: $mode ###"
    for a in "${AUDITS[@]}"; do
        bash "$ONE" "$a" "$mode"
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "BATCH_STOPPED phase=$mode audit=$a rc=$rc done=$(wc -l < "$DONE")/$TOTAL"
            echo "  -> re-run this script after quota refreshes / re-login to continue."
            exit 1
        fi
    done
done
echo "### BATCH COMPLETE: $(wc -l < "$DONE")/$TOTAL ###"; column -t -s $'\t' "$DONE"
