#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# tests/run_all.sh
# Orchestrator for all test suites — EKS Hybrid Nodes + Burst Scaling
#
# Executes suites in sequence and reports total coverage.
#
# Usage:
#   ./tests/run_all.sh                    # Execute all suites
#   ./tests/run_all.sh --skip-e2e         # Skip E2E test (faster)
#   ./tests/run_all.sh --skip-load        # Skip real load tests
#   ./tests/run_all.sh --suite infra      # Execute only one suite
#   ./tests/run_all.sh --dry-run          # List suites without executing
#
# Environment variables:
#   SKIP_E2E=true          — Skip test_e2e.sh
#   SKIP_LOAD_TESTS=true   — Skip load tests in test_scaling.sh
#   SUITE=<name>           — Execute only the specified suite
#                            (infra|observability|inference|scaling|e2e)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# macOS compatibility: provide 'timeout' if not available (GNU coreutils)
if ! command -v timeout &>/dev/null; then
  timeout() {
    local duration="$1"; shift
    perl -e 'alarm shift; exec @ARGV' "$duration" "$@"
  }
  export -f timeout
fi
RESULTS_DIR="${SCRIPT_DIR}/results"
TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
REPORT_FILE="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

SKIP_E2E="${SKIP_E2E:-false}"
SKIP_LOAD_TESTS="${SKIP_LOAD_TESTS:-false}"
SUITE="${SUITE:-all}"
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------------------------------------------------------
# Colors and helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Global counters (accumulated from all suites)
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
TOTAL_SUITES=0
SUITES_PASSED=0
SUITES_FAILED=0

info()   { echo -e "${BLUE}  ℹ${NC} $1"; }
header() { echo -e "\n${BOLD}${BLUE}$1${NC}"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-e2e)
        SKIP_E2E=true
        shift
        ;;
      --skip-load)
        SKIP_LOAD_TESTS=true
        export SKIP_LOAD_TESTS
        shift
        ;;
      --suite)
        SUITE="${2:-all}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        echo "Usage: $0 [--skip-e2e] [--skip-load] [--suite <name>] [--dry-run]"
        echo ""
        echo "Available suites: infra, observability, inference, scaling, e2e"
        echo ""
        echo "Environment variables:"
        echo "  SKIP_E2E=true          Skip test_e2e.sh"
        echo "  SKIP_LOAD_TESTS=true   Skip load tests"
        echo "  SUITE=<name>           Execute only one suite"
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        exit 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Execute a suite and capture result
# ---------------------------------------------------------------------------
run_suite() {
  local suite_name="$1"
  local suite_file="$2"
  local suite_desc="$3"

  ((TOTAL_SUITES++))

  echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  Suite ${TOTAL_SUITES}: ${suite_desc}${NC}"
  echo -e "${CYAN}  File: ${suite_file}${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}  [DRY-RUN] Skipping execution${NC}"
    return 0
  fi

  if [[ ! -f "$suite_file" ]]; then
    echo -e "${RED}  ✘ File not found: ${suite_file}${NC}"
    ((SUITES_FAILED++))
    return 1
  fi

  if [[ ! -x "$suite_file" ]]; then
    chmod +x "$suite_file"
  fi

  local suite_start
  suite_start=$(date +%s)

  # Execute the suite and capture output + exit code
  local suite_output
  local suite_exit=0

  suite_output=$(bash "$suite_file" 2>&1) || suite_exit=$?

  local suite_end
  suite_end=$(date +%s)
  local suite_duration=$(( suite_end - suite_start ))

  # Display suite output
  echo "$suite_output"

  # Extract counters from suite output
  local suite_passed suite_failed suite_skipped
  suite_passed=$(echo "$suite_output" | grep -o 'Passed [0-9]*' | grep -o '[0-9]*' | tail -1 || echo "0")
  suite_failed=$(echo "$suite_output" | grep -o 'Failed [0-9]*' | grep -o '[0-9]*' | tail -1 || echo "0")
  suite_skipped=$(echo "$suite_output" | grep -o 'Skipped [0-9]*' | grep -o '[0-9]*' | tail -1 || echo "0")

  TOTAL_PASSED=$(( TOTAL_PASSED + ${suite_passed:-0} ))
  TOTAL_FAILED=$(( TOTAL_FAILED + ${suite_failed:-0} ))
  TOTAL_SKIPPED=$(( TOTAL_SKIPPED + ${suite_skipped:-0} ))

  # Save result to report file
  {
    echo "=== Suite: ${suite_desc} ==="
    echo "File: ${suite_file}"
    echo "Duration: ${suite_duration}s"
    echo "Exit code: ${suite_exit}"
    echo "Passed: ${suite_passed:-0} | Failed: ${suite_failed:-0} | Skipped: ${suite_skipped:-0}"
    echo ""
    echo "$suite_output"
    echo ""
  } >> "$REPORT_FILE"

  if [[ "$suite_exit" -eq 0 ]]; then
    echo -e "\n${GREEN}  ✔ Suite '${suite_name}' PASSED (${suite_duration}s)${NC}"
    ((SUITES_PASSED++))
    return 0
  else
    echo -e "\n${RED}  ✘ Suite '${suite_name}' FAILED (${suite_duration}s)${NC}"
    ((SUITES_FAILED++))
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Calculate architecture coverage
# Compatible with bash 3 (macOS) — no declare -A
# ---------------------------------------------------------------------------
calculate_coverage() {
  # Format: "component:suite"
  local component_map=(
    "EKS_Managed_Nodes:infra"
    "EKS_Hybrid_Node:infra"
    "GPUs_Allocatable:infra"
    "Cilium_CNI:infra"
    "Transit_Gateway:infra"
    "Security_Groups:infra"
    "DNS_Cross_VPC:infra"
    "Prometheus:observability"
    "Grafana:observability"
    "DCGM_Exporter:observability"
    "vLLM_Metrics:observability"
    "ServiceMonitor:observability"
    "PrometheusRule:observability"
    "vLLM_Health_Endpoint:inference"
    "Chat_Completions_API:inference"
    "Streaming_SSE:inference"
    "Modelo_Qwen3_35B:inference"
    "Latencia_TTFT:inference"
    "Throughput_tokens_s:inference"
    "KEDA_ScaledObject:scaling"
    "Scale_to_Zero:scaling"
    "Karpenter_NodePool_GPU:scaling"
    "Burst_Scale_Up:scaling"
    "NodeClaims_Provisioning:scaling"
    "Scale_Down_Cooldown:scaling"
    "Jornada_E2E_Completa:e2e"
    "GPU_Utilization:e2e"
    "Metricas_durante_carga:e2e"
  )

  local total_components=${#component_map[@]}
  local covered_components=0

  # Determine which suites were executed
  local exec_infra=false exec_obs=false exec_inf=false exec_scal=false exec_e2e=false
  [[ "$SUITE" == "all" || "$SUITE" == "infra" ]]         && exec_infra=true
  [[ "$SUITE" == "all" || "$SUITE" == "observability" ]] && exec_obs=true
  [[ "$SUITE" == "all" || "$SUITE" == "inference" ]]     && exec_inf=true
  [[ "$SUITE" == "all" || "$SUITE" == "scaling" ]]       && exec_scal=true
  if { [[ "$SUITE" == "all" ]] && [[ "$SKIP_E2E" != "true" ]]; } || [[ "$SUITE" == "e2e" ]]; then
    exec_e2e=true
  fi

  for entry in "${component_map[@]}"; do
    local suite="${entry##*:}"
    local covered=false
    case "$suite" in
      infra)         [[ "$exec_infra" == "true" ]] && covered=true ;;
      observability) [[ "$exec_obs"   == "true" ]] && covered=true ;;
      inference)     [[ "$exec_inf"   == "true" ]] && covered=true ;;
      scaling)       [[ "$exec_scal"  == "true" ]] && covered=true ;;
      e2e)           [[ "$exec_e2e"   == "true" ]] && covered=true ;;
    esac
    [[ "$covered" == "true" ]] && ((covered_components++))
  done

  local coverage_pct=0
  if [[ "$total_components" -gt 0 ]]; then
    coverage_pct=$(echo "scale=1; $covered_components * 100 / $total_components" | bc 2>/dev/null || echo "0")
  fi

  echo "$coverage_pct"
}

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
print_final_report() {
  local total_tests=$(( TOTAL_PASSED + TOTAL_FAILED + TOTAL_SKIPPED ))
  local pass_rate=0
  if [[ "$total_tests" -gt 0 ]]; then
    pass_rate=$(echo "scale=1; $TOTAL_PASSED * 100 / $total_tests" | bc 2>/dev/null || echo "0")
  fi

  local coverage
  coverage=$(calculate_coverage)

  echo -e "\n${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║  FINAL REPORT — EKS Hybrid Nodes + Burst Scaling                ║${NC}"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  Timestamp: ${TIMESTAMP}"
  echo -e "${BOLD}${BLUE}║${NC}  Report saved to: ${REPORT_FILE}"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}Suites executed:${NC} ${TOTAL_SUITES}"
  echo -e "${BOLD}${BLUE}║${NC}    ${GREEN}✔ Passed: ${SUITES_PASSED}${NC}"
  echo -e "${BOLD}${BLUE}║${NC}    ${RED}✘ Failed: ${SUITES_FAILED}${NC}"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}Individual tests:${NC} ${total_tests}"
  echo -e "${BOLD}${BLUE}║${NC}    ${GREEN}✔ Passed: ${TOTAL_PASSED}${NC}"
  echo -e "${BOLD}${BLUE}║${NC}    ${RED}✘ Failed: ${TOTAL_FAILED}${NC}"
  echo -e "${BOLD}${BLUE}║${NC}    ${YELLOW}⊘ Skipped: ${TOTAL_SKIPPED}${NC}"
  echo -e "${BOLD}${BLUE}║${NC}    Pass rate: ${pass_rate}%"
  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}Architecture coverage:${NC} ${coverage}% (target: 90%)"

  # Coverage progress bar
  local bar_filled=$(echo "scale=0; $coverage / 5" | bc 2>/dev/null || echo "0")
  local bar_empty=$(( 20 - bar_filled ))
  local bar="${GREEN}"
  [[ $(echo "$coverage < 90" | bc 2>/dev/null || echo "1") -eq 1 ]] && bar="${YELLOW}"
  [[ $(echo "$coverage < 70" | bc 2>/dev/null || echo "1") -eq 1 ]] && bar="${RED}"
  local bar_str="${bar}$(printf '█%.0s' $(seq 1 $bar_filled 2>/dev/null || echo ""))${NC}$(printf '░%.0s' $(seq 1 $bar_empty 2>/dev/null || echo ""))"
  echo -e "${BOLD}${BLUE}║${NC}  [${bar_str}] ${coverage}%"

  echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"

  # Final recommendation
  if [[ "$TOTAL_FAILED" -eq 0 && "$SUITES_FAILED" -eq 0 ]]; then
    echo -e "${BOLD}${BLUE}║${NC}  ${GREEN}${BOLD}✔ RECOMMENDATION: PASSED${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${GREEN}  All tests passed. Platform validated.${NC}"
  else
    echo -e "${BOLD}${BLUE}║${NC}  ${RED}${BOLD}✘ RECOMMENDATION: FAILED${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${RED}  ${TOTAL_FAILED} test(s) failing in ${SUITES_FAILED} suite(s).${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${RED}  See report: ${REPORT_FILE}${NC}"
  fi

  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"

  # Save summary to report
  {
    echo ""
    echo "=== FINAL SUMMARY ==="
    echo "Timestamp: ${TIMESTAMP}"
    echo "Suites: ${TOTAL_SUITES} (passed: ${SUITES_PASSED}, failed: ${SUITES_FAILED})"
    echo "Tests: ${total_tests} (passed: ${TOTAL_PASSED}, failed: ${TOTAL_FAILED}, skipped: ${TOTAL_SKIPPED})"
    echo "Pass rate: ${pass_rate}%"
    echo "Architecture coverage: ${coverage}%"
    if [[ "$TOTAL_FAILED" -eq 0 ]]; then
      echo "Recommendation: PASSED"
    else
      echo "Recommendation: FAILED"
    fi
  } >> "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Create results directory
  mkdir -p "$RESULTS_DIR"

  # Initialize report file
  {
    echo "Test Report — EKS Hybrid Nodes + Burst Scaling"
    echo "Timestamp: ${TIMESTAMP}"
    echo "SKIP_E2E: ${SKIP_E2E}"
    echo "SKIP_LOAD_TESTS: ${SKIP_LOAD_TESTS}"
    echo "SUITE: ${SUITE}"
    echo ""
  } > "$REPORT_FILE"

  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║  run_all.sh — EKS Hybrid Nodes + Burst Scaling Test Suite      ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo -e "Timestamp: ${TIMESTAMP}"
  echo -e "SKIP_E2E: ${SKIP_E2E} | SKIP_LOAD_TESTS: ${SKIP_LOAD_TESTS} | SUITE: ${SUITE}"
  echo -e "Report: ${REPORT_FILE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "\n${YELLOW}DRY-RUN mode enabled — suites will be listed but not executed${NC}"
  fi

  # Define suites to execute
  local run_infra=false
  local run_observability=false
  local run_inference=false
  local run_scaling=false
  local run_e2e=false

  case "$SUITE" in
    all)
      run_infra=true
      run_observability=true
      run_inference=true
      run_scaling=true
      [[ "$SKIP_E2E" != "true" ]] && run_e2e=true
      ;;
    infra)         run_infra=true ;;
    observability) run_observability=true ;;
    inference)     run_inference=true ;;
    scaling)       run_scaling=true ;;
    e2e)           run_e2e=true ;;
    *)
      echo -e "${RED}Unknown suite: ${SUITE}${NC}"
      echo "Valid suites: all, infra, observability, inference, scaling, e2e"
      exit 1
      ;;
  esac

  # Export variables for child suites
  export SKIP_LOAD_TESTS

  # Execute selected suites
  local overall_exit=0

  if [[ "$run_infra" == "true" ]]; then
    run_suite "infra" \
      "${SCRIPT_DIR}/test_infrastructure.sh" \
      "Infrastructure (Nodes, GPUs, Cilium, TGW, SGs, DNS)" || overall_exit=1
  fi

  if [[ "$run_observability" == "true" ]]; then
    run_suite "observability" \
      "${SCRIPT_DIR}/test_observability.sh" \
      "Observability (Prometheus, Grafana, DCGM, vLLM Metrics)" || overall_exit=1
  fi

  if [[ "$run_inference" == "true" ]]; then
    run_suite "inference" \
      "${SCRIPT_DIR}/test_inference.sh" \
      "Inference (vLLM Health, Chat, Streaming, Latency, Throughput)" || overall_exit=1
  fi

  if [[ "$run_scaling" == "true" ]]; then
    run_suite "scaling" \
      "${SCRIPT_DIR}/test_scaling.sh" \
      "Scalability (KEDA, Scale-to-Zero, Karpenter, Burst, Scale-Down)" || overall_exit=1
  fi

  if [[ "$run_e2e" == "true" ]]; then
    echo -e "\n${YELLOW}⚠ E2E Suite: takes ~15-20 minutes. Press Ctrl+C to cancel.${NC}"
    sleep 3
    run_suite "e2e" \
      "${SCRIPT_DIR}/test_e2e.sh" \
      "End-to-End (Full journey: deploy → load → burst → scale-down)" || overall_exit=1
  elif [[ "$SUITE" == "all" && "$SKIP_E2E" == "true" ]]; then
    echo -e "\n${YELLOW}  ⊘ E2E Suite skipped (SKIP_E2E=true)${NC}"
  fi

  print_final_report

  exit "$overall_exit"
}

main "$@"
