#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
AUDIO_ENGINE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DURATION_SECS="${AUDIO_ENGINE_TEST_DURATION_SECS:-1800}"
CHANNEL_COUNT="${AUDIO_ENGINE_TEST_CHANNEL_COUNT:-48}"
CAPTURE_MODE="${AUDIO_ENGINE_CAPTURE_MODE:-alsa}"
REQUIRE_REBIND="0"
CARGO_BIN="${CARGO_BIN:-cargo}"
RUSTC_BIN="${RUSTC_BIN:-}"
LOG_FILE=""

usage() {
  cat <<'EOF'
Run Milestone 2 acceptance validation for audio-engine.

Usage:
  run_milestone2_acceptance.sh [options]

Options:
  --duration-secs <n>      Test window in seconds (default: 1800)
  --channel-count <n>      Source activity channels to summarize (default: 48)
  --capture-mode <mode>    Capture mode (default: alsa)
  --log-file <path>        Output log path (default: audio-engine/logs/m2-<timestamp>.log)
  --require-rebind         Fail unless auto-rebind evidence appears in log
  --cargo-bin <path>       Cargo executable (default: cargo)
  --rustc-bin <path>       Optional rustc executable; exported as RUSTC
  -h, --help               Show this help

Environment knobs are forwarded to audio-engine as-is.
This script only sets missing defaults for test-window variables.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration-secs)
      DURATION_SECS="${2:-}"
      shift 2
      ;;
    --channel-count)
      CHANNEL_COUNT="${2:-}"
      shift 2
      ;;
    --capture-mode)
      CAPTURE_MODE="${2:-}"
      shift 2
      ;;
    --log-file)
      LOG_FILE="${2:-}"
      shift 2
      ;;
    --require-rebind)
      REQUIRE_REBIND="1"
      shift
      ;;
    --cargo-bin)
      CARGO_BIN="${2:-}"
      shift 2
      ;;
    --rustc-bin)
      RUSTC_BIN="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! "${DURATION_SECS}" =~ ^[0-9]+$ ]] || [[ "${DURATION_SECS}" == "0" ]]; then
  echo "--duration-secs must be a positive integer" >&2
  exit 2
fi

if [[ ! "${CHANNEL_COUNT}" =~ ^[0-9]+$ ]] || [[ "${CHANNEL_COUNT}" == "0" ]]; then
  echo "--channel-count must be a positive integer" >&2
  exit 2
fi

LOG_DIR="${AUDIO_ENGINE_DIR}/logs"
mkdir -p "${LOG_DIR}"
if [[ -z "${LOG_FILE}" ]]; then
  LOG_FILE="${LOG_DIR}/m2-acceptance-$(date +%Y%m%d-%H%M%S).log"
fi

export AUDIO_ENGINE_TEST_DURATION_SECS="${DURATION_SECS}"
export AUDIO_ENGINE_TEST_CHANNEL_COUNT="${CHANNEL_COUNT}"
export AUDIO_ENGINE_CAPTURE_MODE="${CAPTURE_MODE}"

cd "${AUDIO_ENGINE_DIR}"

echo "[INFO] Starting Milestone 2 acceptance run"
echo "[INFO] duration=${DURATION_SECS}s channels=${CHANNEL_COUNT} capture_mode=${CAPTURE_MODE}"
echo "[INFO] log=${LOG_FILE}"

if [[ -n "${RUSTC_BIN}" ]]; then
  RUSTC="${RUSTC_BIN}" "${CARGO_BIN}" run --release 2>&1 | tee "${LOG_FILE}"
else
  "${CARGO_BIN}" run --release 2>&1 | tee "${LOG_FILE}"
fi
run_exit="${PIPESTATUS[0]}"

if [[ "${run_exit}" != "0" ]]; then
  echo "[FAIL] audio-engine exited with status ${run_exit}" >&2
  exit "${run_exit}"
fi

all_ok="1"
check_pattern() {
  local pattern="$1"
  local label="$2"
  if grep -Eq "${pattern}" "${LOG_FILE}"; then
    echo "[PASS] ${label}"
  else
    echo "[FAIL] ${label}" >&2
    all_ok="0"
  fi
}

check_pattern "test window completed: ${DURATION_SECS} seconds" "bounded test window completed"
check_pattern "--- Packet Integrity Summary ---" "packet integrity summary emitted"
check_pattern "sequence_gaps=0" "sequence gap count remains zero"
check_pattern "duplicate_sequences=0" "duplicate sequence count remains zero"
check_pattern "timestamp_regressions=0" "timestamp regression count remains zero"
check_pattern "pipeline healthy:" "pipeline health logs present"

max_dropped="$(grep -Eo 'dropped_queue_full=[0-9]+' "${LOG_FILE}" | cut -d= -f2 | sort -nr | head -n1 || true)"
if [[ -z "${max_dropped}" ]]; then
  echo "[FAIL] no dropped_queue_full metrics found in log" >&2
  all_ok="0"
elif [[ "${max_dropped}" == "0" ]]; then
  echo "[PASS] dropped_queue_full remained zero"
else
  echo "[FAIL] dropped_queue_full observed max=${max_dropped}" >&2
  all_ok="0"
fi

if [[ "${REQUIRE_REBIND}" == "1" ]]; then
  check_pattern "Attempting auto-rebind|ALSA rebind switched device" "rebind evidence found"
else
  echo "[INFO] Rebind evidence check skipped (use --require-rebind after unplug/replug test)."
fi

if [[ "${all_ok}" == "1" ]]; then
  echo "[PASS] Milestone 2 acceptance checks passed."
  exit 0
fi

echo "[FAIL] Milestone 2 acceptance checks failed. See ${LOG_FILE}" >&2
exit 1
