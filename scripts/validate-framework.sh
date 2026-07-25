#!/usr/bin/env bash
# validate-framework.sh - Comprehensive framework validation (dynamic).
#
# Validates the Claude Code CLI Agentic Framework integrity. All "truth" is
# DERIVED at runtime from claude.json + the filesystem via the shared facts
# layer (scripts/lib/facts.sh): there is NO frozen EXPECTED_AGENTS array and NO
# hardcoded agent count anywhere in this script.
#
# Structure:
#   Steps 1-2 here perform lightweight structural checks (core files +
#   directories). The deep consistency battery (registry<->fs parity, category
#   partition, hook coverage, JSON/YAML validity, deprecated names, arch
#   strings, stated-count scan, model parity) is delegated to the single source
#   of truth, validate-consistency.sh, so the two never drift apart.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/facts.sh
source "$SCRIPT_DIR/lib/facts.sh"

ROOT="$FACTS_REPO_ROOT"

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; NC=""
fi

echo "🔍 Claude Code CLI Agentic Framework Validator"
echo "================================================"
echo ""

ERRORS=0
WARNINGS=0

# Derived facts (no hardcoded values).
N_AGENTS="$(fact_agents | grep -c . || true)"

echo "📋 Step 1: Validating Core Files"
echo "--------------------------------"

for core in CLAUDE.md claude.json settings.template.json hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json mcp-plugin/.claude-plugin/plugin.json mcp-plugin/.mcp.json; do
  if [[ -f "$ROOT/$core" ]]; then
    echo -e "${GREEN}✅${NC} $core found"
  else
    echo -e "${RED}❌${NC} $core missing"
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ -f "$ROOT/claude.json" ]]; then
  if jq empty "$ROOT/claude.json" >/dev/null 2>&1; then
    echo -e "${GREEN}✅${NC} claude.json has valid JSON syntax"
  else
    echo -e "${RED}❌${NC} claude.json has invalid JSON syntax"
    ERRORS=$((ERRORS + 1))
  fi
fi

if [[ -f "$ROOT/README.md" ]]; then
  echo -e "${GREEN}✅${NC} README.md found"
else
  echo -e "${YELLOW}⚠️${NC}  README.md missing"
  WARNINGS=$((WARNINGS + 1))
fi

echo ""
echo "📁 Step 2: Validating Directories"
echo "--------------------------------"

for dir in agents commands hooks skills scripts tests docs; do
  if [[ -d "$ROOT/$dir" ]]; then
    echo -e "${GREEN}✅${NC} $dir/ directory exists"
  else
    echo -e "${RED}❌${NC} $dir/ directory missing"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "🤖 Step 3: Deep Consistency Checks (delegated to validate-consistency.sh)"
echo "------------------------------------------------------------------------"
echo "Expected agents (derived from claude.json): ${N_AGENTS}"
echo ""

# Delegate the authoritative, dynamic checks to the single source of truth.
if ! bash "$SCRIPT_DIR/validate-consistency.sh"; then
  ERRORS=$((ERRORS + 1))
fi

echo ""
echo "📊 Validation Summary"
echo "===================="
echo ""

if [[ "$ERRORS" -eq 0 && "$WARNINGS" -eq 0 ]]; then
  echo -e "${GREEN}🎉 PERFECT!${NC} Framework validation passed with no errors or warnings"
  echo ""
  echo "✅ All core files present"
  echo "✅ All ${N_AGENTS} agents consistent (registry == filesystem)"
  echo "✅ Consistency battery passed"
  exit 0
elif [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${YELLOW}⚠️  WARNINGS FOUND${NC}"
  echo "Errors: 0"
  echo "Warnings: $WARNINGS"
  echo ""
  echo "Framework is functional but has minor issues"
  exit 0
else
  echo -e "${RED}❌ VALIDATION FAILED${NC}"
  echo "Errors: $ERRORS"
  echo "Warnings: $WARNINGS"
  echo ""
  echo "Please fix the errors above before using the framework"
  exit 1
fi
