#!/bin/bash

# Security Validation Script
# Quick check for common sensitive information patterns

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "🔒 Security Validation Script"
echo "=============================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check for hardcoded secrets.
# The VALUE must be a LITERAL: a value whose first character is '$' is a shell
# expansion — "$SOME_VAR" or "$(command ...)" — and a hardcoded secret is by
# definition not an expansion. Encoding that in the pattern ([^"'$] for the
# first value character) stops the rule from flagging ordinary code such as
# tool_tokens="$(...)", which cost a CI round with nothing to fix.
# Exception filters (in order): placeholder values, test fixtures, documented
# examples, env-var expansion, template placeholders ({{ ... }}), and lines
# explicitly marked as educational anti-patterns in agent prompts.
_secret_scan() {
    grep -r --exclude-dir=.git -i -E "(password|secret|key|token).*[=:]\s*[\"'][^\"'\$][^\"']{7,}[\"']" . \
        | grep -v "your-api-key" \
        | grep -v "test123" \
        | grep -v -i "example" \
        | grep -v '\${.*}' \
        | grep -v '{{.*}}' \
        | grep -v "NEVER DO THIS"
}

echo "🔍 Checking for hardcoded secrets..."
if _secret_scan > /dev/null 2>&1; then
    echo -e "${RED}❌ Potential hardcoded secrets found:${NC}"
    _secret_scan
    exit 1
else
    echo -e "${GREEN}✅ No hardcoded secrets detected${NC}"
fi

# Check for AWS keys
echo ""
echo "🔍 Checking for AWS access keys..."
if grep -r --exclude-dir=.git -E "AKIA[0-9A-Z]{16}" . > /dev/null 2>&1; then
    echo -e "${RED}❌ AWS access keys found:${NC}"
    grep -r --exclude-dir=.git -E "AKIA[0-9A-Z]{16}" .
    exit 1
else
    echo -e "${GREEN}✅ No AWS access keys detected${NC}"
fi

# Check for GitHub tokens
echo ""
echo "🔍 Checking for GitHub tokens..."
if grep -r --exclude-dir=.git -E "ghp_[0-9a-zA-Z]{36}" . > /dev/null 2>&1; then
    echo -e "${RED}❌ GitHub tokens found:${NC}"
    grep -r --exclude-dir=.git -E "ghp_[0-9a-zA-Z]{36}" .
    exit 1
else
    echo -e "${GREEN}✅ No GitHub tokens detected${NC}"
fi

# Check for private keys
echo ""
echo "🔍 Checking for private keys..."
if grep -r --exclude-dir=.git --exclude="security-check.sh" -e "-----BEGIN.*PRIVATE KEY-----" . > /dev/null 2>&1; then
    echo -e "${RED}❌ Private keys found:${NC}"
    grep -r --exclude-dir=.git --exclude="security-check.sh" -e "-----BEGIN.*PRIVATE KEY-----" .
    exit 1
else
    echo -e "${GREEN}✅ No private keys detected${NC}"
fi

# Check for .env files (should only be .env.example)
echo ""
echo "🔍 Checking for environment files..."
ENV_FILES=$(find . -name ".env" -not -name "*.example" -type f 2>/dev/null || true)
if [ -n "$ENV_FILES" ]; then
    echo -e "${YELLOW}⚠️  Found .env files (should be in .gitignore):${NC}"
    echo "$ENV_FILES"
    echo -e "${YELLOW}   Make sure these contain no real credentials and are gitignored${NC}"
else
    echo -e "${GREEN}✅ No problematic .env files found${NC}"
fi

# Check for database connection strings
echo ""
echo "🔍 Checking for database connection strings with credentials..."
if grep -r --exclude-dir=.git --exclude="security-check.sh" -i -E "(mongodb://|mysql://|postgres://|redis://)[^@]*:[^@]*@" . > /dev/null 2>&1; then
    echo -e "${RED}❌ Database connection strings with credentials found:${NC}"
    grep -r --exclude-dir=.git --exclude="security-check.sh" -i -E "(mongodb://|mysql://|postgres://|redis://)[^@]*:[^@]*@" .
    exit 1
else
    echo -e "${GREEN}✅ No database connection strings with credentials detected${NC}"
fi

# Validate .gitignore has security exclusions
echo ""
echo "🔍 Checking .gitignore security configuration..."
if [ -f ".gitignore" ]; then
    if grep -q "credentials" .gitignore && grep -q "settings.local" .gitignore; then
        echo -e "${GREEN}✅ .gitignore includes security exclusions${NC}"
    else
        echo -e "${YELLOW}⚠️  .gitignore should include credential exclusions${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  No .gitignore file found${NC}"
fi

echo ""
echo "=============================="
echo -e "${GREEN}🎉 Security validation completed successfully!${NC}"
echo ""
echo "📝 CI runs this on every PR (.github/workflows/consistency.yml)."
echo "📖 For full audit report, see: SECURITY_AUDIT.md"