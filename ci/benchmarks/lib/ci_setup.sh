#!/usr/bin/env bash
# ci_setup.sh — idempotently prepare the self-hosted runner for ONE benchmark.
# Creates a cached py3.12 venv + benchmark deps/clones OUTSIDE the checkout (so they
# survive between jobs), ensures the claude-code optimizer CLI is installed, preflights the
# model gateway (fail fast when the SELECTED models are not entitled, or the gateway is over
# budget, rather than score all-0.000), and exports CAPEVOLVE_PY / SKILLSBENCH_SRC / PATH to
# $GITHUB_ENV.
#
#   ci_setup.sh <bench>
set -euo pipefail
BENCH="${1:?bench}"
CACHE="${CAPEVOLVE_CI_CACHE:-$HOME/.cache/capevolve-ci}"
VENV="$CACHE/venv"
CAPEVOLVE_PY="$VENV/bin/python"
IDX="--index-url https://pypi.org/simple"
mkdir -p "$CACHE"

command -v uv >/dev/null || { echo "::error:: uv is required on the runner"; exit 1; }
[ -x "$CAPEVOLVE_PY" ] || uv venv --python 3.12 "$VENV"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$LIB_DIR/../../.." && pwd)"
uv pip install -p "$CAPEVOLVE_PY" -q $IDX "$REPO/core" litellm

case "$BENCH" in
  swebench)
    # Harbor is the ONLY swebench adapter. It runs a real coding agent (claude-code) inside
    # its own sandboxed containers and manages its own dataset, so none of the removed litellm
    # path's machinery is needed: no HuggingFace dataset, no oracle context, no
    # swebench/sweb.eval.* images, no per-instance patch application.
    #
    # Why: the curated tiers' task ids are SWE-bench_Verified, but oracle code context exists
    # only for Lite (46 of full's 250 had it), and single-shot blind patching is not a
    # meaningful target for a mid-tier model. Harbor's agent explores the repo itself.
    # The adapter does `from capevolve_harbor import ...`; that package lives in this repo
    # and was never installed into the CI venv, so the harbor path would have died on
    # import. Install it explicitly.
    uv pip install -p "$CAPEVOLVE_PY" -q $IDX "$REPO/capevolve_harbor"
    "$CAPEVOLVE_PY" -c "import capevolve_harbor; print('capevolve_harbor OK')"
    command -v harbor >/dev/null 2>&1 || uv tool install $IDX harbor >/dev/null 2>&1 || true
    command -v harbor >/dev/null || {
      echo "::error:: harbor CLI unavailable — the harbor adapter cannot run a single task."
      exit 1; }
    echo "harbor: $(command -v harbor)"
    command -v docker >/dev/null && docker info >/dev/null 2>&1 || {
      echo "::error:: docker daemon not reachable — harbor runs every task in a container"
      exit 1; }
    # Reap orphaned harbor task containers before starting. Harbor does NOT tear its
    # containers down when a workflow run is cancelled — 6 were found stranded 27-47 hours
    # after their runs ended, competing for CPU and memory with whatever ran next. The bench
    # leg is serialized on this single self-hosted runner, so any *__env-main container alive
    # at setup time can only be a leftover. (This replaces the sweb.eval.* reaper, which
    # became dead along with the litellm adapter.)
    hb_orphans=$(docker ps -aq --filter "name=env-main" 2>/dev/null | tr '\n' ' ')
    if [ -n "$(printf '%s' "$hb_orphans" | tr -d ' ')" ]; then
      # shellcheck disable=SC2086 -- intentional word splitting over container ids
      docker rm -f $hb_orphans >/dev/null 2>&1 || true
      echo "reaped $(printf '%s' "$hb_orphans" | wc -w | tr -d ' ') orphaned harbor container(s)"
    fi
    ;;
  tau2)
    [ -d "$CACHE/tau2-bench/.git" ] || git clone --depth 1 https://github.com/sierra-research/tau2-bench "$CACHE/tau2-bench"
    uv pip install -p "$CAPEVOLVE_PY" -q $IDX -e "$CACHE/tau2-bench" ;;
  skillsbench)
    uv tool install $IDX benchflow >/dev/null 2>&1 || true
    [ -d "$CACHE/skillsbench-src/.git" ] || GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 https://github.com/benchflow-ai/skillsbench "$CACHE/skillsbench-src" ;;
  spreadsheetbench)
    uv pip install -p "$CAPEVOLVE_PY" -q $IDX pandas openpyxl docker tornado requests
    command -v docker >/dev/null && docker info >/dev/null 2>&1 || {
      echo "::error:: docker daemon not reachable — spreadsheetbench runs each task in its own container"; exit 1; }
    if ! command -v libreoffice >/dev/null 2>&1 && ! command -v soffice >/dev/null 2>&1; then
      echo "::warning:: LibreOffice not found — formula-only cells won't be recalculated before scoring"
    fi
    SB_VARIANT="sample_200"
    # pilot's tasks are drawn from full's train split, so it needs the 912-task dataset too.
    case "${TIER:-smoke}" in full|pilot) SB_VARIANT="full_912";; esac
    SPREADSHEETBENCH_DATA_DIR="$(SPREADSHEETBENCH_VARIANT="$SB_VARIANT" "$REPO/ci/benchmarks/spreadsheetbench/fetch_data.sh" "$CACHE/spreadsheetbench-data")" ;;
esac

"$CAPEVOLVE_PY" -c "import cap_evolve; print('cap_evolve OK')"

# Ensure the claude-code optimizer CLI (the EDIT PROPOSER) is present. If a runner is
# reprovisioned/rebooted the global npm install can vanish; without `claude` the benchmark
# SILENTLY degrades — the optimizer fails every iteration with `cli_present:false`, no edit
# is proposed, and every task reports best=seed / reward 0.000 as if it had "optimized".
# Install idempotently into a user-writable prefix ($HOME/.local/bin is already on PATH and
# exported below), then HARD-FAIL if it is still unavailable so a broken runner is loud.
if ! command -v claude >/dev/null 2>&1; then
  command -v npm >/dev/null || { echo "::error:: npm required to install the claude-code optimizer"; exit 1; }
  echo "claude CLI missing — installing @anthropic-ai/claude-code into $HOME/.local"
  npm install -g --prefix "$HOME/.local" @anthropic-ai/claude-code
fi
export PATH="$HOME/.local/bin:$PATH"
command -v claude >/dev/null || {
  echo "::error:: claude-code optimizer CLI still unavailable after install — aborting."
  echo "::error:: (running anyway would silently yield best=seed / reward 0.000 on every task.)"
  exit 1
}
echo "claude-code optimizer: $(command -v claude) ($(claude --version 2>/dev/null | head -1))"

# Gateway preflight — ENTITLEMENT first, then BUDGET. The agent AND the optimizer share one
# LiteLLM gateway, and both of these faults present identically: every rollout dies with
# INFRASTRUCTURE_ERROR and the suite reports a clean-looking 0.000 that is indistinguishable
# from a real regression. Detect both up front rather than burn hours and dollars.
#
# ENTITLEMENT is the one that actually bites. The model dropdowns in benchmarks.yml are a
# STATIC list; the gateway's per-team allowlist is not, so they drift apart. Run 31124146014
# selected `Azure/gpt-5-mini-2025-08-07` — in the dropdown, absent from the key's allowlist —
# and spent 11 minutes plus $2.56 of optimizer budget before assert_run.py noticed that all
# 5 tasks had infra-errored. 15 of that dropdown's 30 agent options were in the same state,
# including its own default `aws/gpt-oss-120b`.
#
# The previous probe could not have caught that: it asked about a HARDCODED
# `aws/gpt-oss-120b` instead of the models the run actually selected, and only hard-failed on
# HTTP 429 budget_exceeded — so a `team not allowed to access model` rejection printed
# "(not budget-blocked)" and sailed straight through.
if [ -n "${ANTHROPIC_BASE_URL:-}" ] && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && command -v curl >/dev/null; then
  PF_AGENT="${AGENT_MODEL:-aws/gpt-oss-120b}"
  PF_OPTIMIZER="${OPTIMIZER_MODEL:-claude-opus-4-8}"

  # 1. ENTITLEMENT — is each SELECTED model served to this key at all?
  # /models is an `llm_api_routes` call. The richer /model/info and /key/info are NOT: these
  # virtual keys are route-scoped and answer both with 403 "not allowed to call this route",
  # which is also the real reason the old preflight logged a mystery HTTP 403.
  models=/tmp/capevolve_models.$$.json
  mcode="$(curl -sS -m 30 -o "$models" -w '%{http_code}' \
    "$ANTHROPIC_BASE_URL/models" \
    -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" 2>/dev/null || echo 000)"
  if [ "$mcode" = "200" ]; then
    if ! "$CAPEVOLVE_PY" "$LIB_DIR/check_models.py" "$models" \
        --require agent="$PF_AGENT" --require optimizer="$PF_OPTIMIZER"; then
      rm -f "$models"; exit 1
    fi
  else
    echo "::warning:: gateway /models returned HTTP $mcode — cannot verify model entitlement"
  fi
  rm -f "$models"

  # 2. BUDGET + call-time entitlement — one real completion with the SELECTED agent model.
  # Listing a model is necessary but not sufficient: the team check happens at call time.
  # `max_completion_tokens` (not `max_tokens`) is used because the Azure reasoning
  # deployments reject the latter outright, and a probe that 400s on its own parameters
  # would be a false alarm.
  probe=/tmp/capevolve_budget_probe.$$.json
  code="$(curl -sS -m 60 -o "$probe" -w '%{http_code}' \
    "$ANTHROPIC_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$PF_AGENT\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_completion_tokens\":16}" \
    2>/dev/null || echo 000)"
  if [ "$code" = "429" ] && grep -qi 'budget' "$probe" 2>/dev/null; then
    echo "::error:: model gateway is OVER BUDGET (HTTP 429 budget_exceeded) — aborting."
    echo "::error:: every rollout would score 0.000 as INFRASTRUCTURE_ERROR. Raise/reset the gateway budget."
    head -c 300 "$probe" 2>/dev/null; echo; rm -f "$probe"; exit 1
  fi
  if grep -qi 'not allowed to access model' "$probe" 2>/dev/null; then
    echo "::error:: gateway REFUSED agent model '$PF_AGENT' at call time (HTTP $code):"
    echo "::error:: the key's team is not entitled to it, so every rollout would fail and the"
    echo "::error:: suite would publish a fake 0.000. Pick a model this key can call."
    head -c 600 "$probe" 2>/dev/null; echo; rm -f "$probe"; exit 1
  fi
  rm -f "$probe"
  echo "gateway preflight: agent='$PF_AGENT' optimizer='$PF_OPTIMIZER' entitled; completion probe HTTP $code (not budget-blocked)"
fi

# Export for later workflow steps (no-op locally).
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "CAPEVOLVE_PY=$CAPEVOLVE_PY"
    echo "SKILLSBENCH_SRC=$CACHE/skillsbench-src"
    if [ -n "${SPREADSHEETBENCH_DATA_DIR:-}" ]; then echo "SPREADSHEETBENCH_DATA_DIR=$SPREADSHEETBENCH_DATA_DIR"; fi
    echo "PATH=$HOME/.local/bin:$PATH"
  } >> "$GITHUB_ENV"
fi
echo "ci_setup done for $BENCH (venv: $VENV)"
