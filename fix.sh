#!/bin/bash

# AUTHOR: LixGhost
# DESC: Auto-scan, patch, build, and start Next.js projects (CVE-2025-55182)
# USAGE: ./fix-next-rce-auto.sh [base_dir] (default: current dir)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="${1:-.}"
FIXED=0
BUILT=0
STARTED=0
VULN_FOUND=0

echo -e "${BLUE}🔍 Scanning for vulnerable Next.js projects in: $BASE_DIR${NC}"

get_package_manager() {
    [[ -f "$1/package-lock.json" ]] && echo "npm" && return
    [[ -f "$1/yarn.lock" ]] && echo "yarn" && return
    [[ -f "$1/pnpm-lock.yaml" ]] && echo "pnpm" && return
    echo "npm"  # default
}

run_cmd() {
    local dir=$1; shift
    local cmd="$@"
    (
        cd "$dir"
        echo -e "${BLUE}⚙️  [$dir] Running: $cmd${NC}"
        eval "$cmd"
    ) || {
        echo -e "${RED}❌ [$dir] Command failed: $cmd${NC}"
        return 1
    }
}

patch_and_rebuild() {
    local dir=$1
    local next_version=$2
    local react_version=$3
    local pkg_manager=$(get_package_manager "$dir")
    local start_cmd=""

    echo -e "\n${YELLOW}🛠️  Patching: $dir${NC}"

    # 1. Update dependencies
    local install_cmd="$pkg_manager add next@$next_version react@$react_version react-dom@$react_version"
    if ! run_cmd "$dir" "$install_cmd"; then
        echo -e "${RED}💥 Failed to install updates${NC}"
        return 1
    fi

    # 2. Hapus cache
    run_cmd "$dir" "rm -rf .next/" || true

    # 3. Build ulang
    echo -e "${BLUE}📦 [$dir] Building...${NC}"
    if run_cmd "$dir" "$pkg_manager run build"; then
        BUILT=$((BUILT + 1))
        echo -e "${GREEN}✅ [$dir] Build success!${NC}"
    else
        echo -e "${RED}❌ [$dir] Build failed! Check logs.${NC}"
        return 1
    fi

    # 4. Auto-start (hanya kalo bukan di production/Vercel)
    # Cek kalo bukan di CI atau server production
    if [[ -z "${CI:-}" ]] && [[ "$dir" != */prod* ]] && [[ "$dir" != */production* ]]; then
        echo -e "${BLUE}▶️  [$dir] Starting in background...${NC}"
        (
            cd "$dir"
            $pkg_manager run start > .next/start.log 2>&1 &
            echo $! > .next/start.pid
        )
        echo -e "${GREEN}✅ [$dir] Started! PID saved in .next/start.pid${NC}"
        STARTED=$((STARTED + 1))
    else
        echo -e "${YELLOW}ℹ️  [$dir] Skipping auto-start (CI/production detected)${NC}"
    fi

    FIXED=$((FIXED + 1))
}

check_and_patch() {
    local dir=$(dirname "$1")
    local pkg_file="$dir/package.json"

    if ! jq -e . "$pkg_file" >/dev/null 2>&1; then return; fi

    local next_ver=$(jq -r '.dependencies."next" // .devDependencies."next" // ""' "$pkg_file" | sed -E 's/[^0-9.]*(.*)/\1/')
    local react_ver=$(jq -r '.dependencies."react" // .devDependencies."react" // ""' "$pkg_file" | sed -E 's/[^0-9.]*(.*)/\1/')

    # Deteksi versi rentan
    if [[ "$next_ver" =~ ^14\.3\.0-canary\.([7-9][7-9]|[8-9][0-9]|[1-9][0-9]{2}) ]] || \
       [[ "$next_ver" =~ ^15\. ]] || \
       [[ "$next_ver" =~ ^16\. ]]; then

        if [[ "$react_ver" == "19.0.0" || "$react_ver" == "19.1.0" || "$react_ver" == "19.1.1" || "$react_ver" == "19.2.0" ]]; then
            echo -e "${RED}🚨 VULNERABLE: $dir${NC}"
            echo "   Next.js: $next_ver | React: $react_ver"
            VULN_FOUND=$((VULN_FOUND + 1))

            if [[ "$next_ver" =~ ^14\.3\.0-canary ]]; then
                patch_and_rebuild "$dir" "14.2.20" "18.2.0"
            else
                local next_safe="15.2.6"
                [[ "$next_ver" =~ ^16\. ]] && next_safe="16.0.7"
                patch_and_rebuild "$dir" "$next_safe" "19.2.1"
            fi
        fi
    fi
}

# 🔎 Scan semua package.json
find "$BASE_DIR" -name "package.json" -not -path "*/node_modules/*" -not -path "*/\.*" | while read -r pkg; do
    check_and_patch "$pkg"
done

# 📊 Summary
echo -e "\n${BLUE}================== FINAL SUMMARY ==================${NC}"
if [[ $VULN_FOUND -eq 0 ]]; then
    echo -e "${GREEN}✅ No vulnerable Next.js projects found!${NC}"
else
    echo -e "${YELLOW}⚠️  Found $VULN_FOUND vulnerable project(s)${NC}"
    echo -e "${GREEN}✅ Patched & Built: $BUILT${NC}"
    [[ $STARTED -gt 0 ]] && echo -e "${GREEN}▶️  Auto-started: $STARTED${NC}"
    [[ $FIXED -lt $VULN_FOUND ]] && echo -e "${RED}❌ Failed: $((VULN_FOUND - FIXED))${NC}"
fi

echo -e "${BLUE}💡 Pro tip: Check .next/start.log for server logs${NC}"
echo -e "${BLUE}🔐 Stay safe, LixGhost got you!${NC}"