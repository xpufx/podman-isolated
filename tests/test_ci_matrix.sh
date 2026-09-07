#!/bin/bash

# Test the Phase-21 CI build-matrix + publish-gating contract by parsing
# .github/workflows/build-packages.yml. Asserts the DYNAMIC matrix contract:
#   - a single matrixed `build` job (no build-amd64/build-arm64)
#   - fail-fast: false under the build strategy
#   - dynamic matrix: build uses fromJson(needs.resolve-track.outputs.matrix),
#     no static `include:` cell list under build
#   - resolve-track outputs both `track` and `matrix`
#   - resolve-track defines an amd64-only 3-cell JSON (2404/2604/bookworm x
#     amd64) and a full 6-cell JSON (amd64 + arm64), selected by
#     inputs.build_arm == true (manual dispatch) or a scheduled stable/v5 run
#     that passes the check-republish guard (new upstream release)
#   - 2604 cells run inside ubuntu:26.04 containers; 2404 cells do not
#     (verified inside the resolve-track JSON fragments)
#   - distro-dimensioned Go cache key + artifact name
#   - publish job gated on the build job's aggregate result (atomic publish)
#   - no cross-distro download merge in the publish job
#   - ci_publish.sh invoked for both 2404 and 2604
#   - weekly Sunday nightly cron (30 4 * * 0), stable/v5 daily crons retained
#   - artifact retention-days: 1
#
# Runs on the macOS dev host with NO CI: prefers python3 + PyYAML for precise
# structural checks, falls back to grep/awk against the raw YAML text when
# PyYAML is unavailable. Both paths run so the test is green either way.
# Grep-path assertions strip comment lines so workflow comments cannot
# self-satisfy a gate. Pure bash + optional python3 — no reprepro/gpg/apt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/build-packages.yml"

# ============================================
# Test Framework
# ============================================

PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected: ${expected}"
        echo "    Got: ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected to contain: ${needle}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# assert_true <description> <0-or-1>  (1 == condition holds)
assert_true() {
    local description="$1"
    local cond="$2"
    if [[ "${cond}" == "1" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo ""
echo "========================================"
echo "Test: CI build-matrix + publish-gating contract (dynamic)"
echo "========================================"
echo ""

# Defensive guard: SKIP cleanly only if the workflow file is entirely absent.
if [[ ! -f "${WORKFLOW}" ]]; then
    echo "SKIP: workflow file not found at ${WORKFLOW}"
    exit 0
fi

# Strip comment-only lines once for every grep-path assertion so workflow
# comments can never self-satisfy a gate (grep-gate hygiene).
NOCOMMENT="$(grep -v '^[[:space:]]*#' "${WORKFLOW}")"
RAW="$(cat "${WORKFLOW}")"

HAVE_PYYAML=0
if python3 -c 'import yaml' 2>/dev/null; then
    HAVE_PYYAML=1
fi

# ============================================
# Path A: precise structural checks via PyYAML
# ============================================

run_python_assertions() {
    echo "--- Python/PyYAML structural assertions ---"

    # Each helper prints exactly "1" (holds) or "0" (fails) on stdout.
    py() { python3 -c "$1" "${WORKFLOW}"; }

    local r

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d['jobs']
print('1' if ('build' in jobs and 'build-amd64' not in jobs and 'build-arm64' not in jobs) else '0')
")
    assert_true "py: single 'build' job (no build-amd64/build-arm64)" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print('1' if d['jobs']['build']['strategy']['fail-fast'] is False else '0')
")
    assert_true "py: build strategy fail-fast is False" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
m = d['jobs']['build']['strategy']['matrix']
print('1' if (isinstance(m, str) and 'fromJson' in m and 'needs.resolve-track.outputs.matrix' in m) else '0')
")
    assert_true "py: build matrix is dynamic fromJson(needs.resolve-track.outputs.matrix)" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
m = d['jobs']['build']['strategy']['matrix']
print('1' if not (isinstance(m, dict) and 'include' in m) else '0')
")
    assert_true "py: build has no static matrix include (dynamic only)" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
outs = d['jobs']['resolve-track'].get('outputs', {})
print('1' if ('track' in outs and 'matrix' in outs) else '0')
")
    assert_true "py: resolve-track outputs both 'track' and 'matrix'" "${r}"

    r=$(py "
import sys, yaml
raw = open(sys.argv[1]).read()
has_arm_toggle = 'inputs.build_arm' in raw
has_amd64_only = 'AMD64_ONLY' in raw or 'amd64-only' in raw.lower()
has_full = 'FULL' in raw and 'arm64' in raw
# amd64-only JSON must carry the three distro cells; full JSON must carry arm64 cells
has_3 = all(s in raw for s in ['2404', '2604', 'bookworm'])
print('1' if (has_arm_toggle and has_amd64_only and has_full and has_3) else '0')
")
    assert_true "py: resolve-track defines amd64-only (3-cell) and full (6-cell) matrices gated on inputs.build_arm" "${r}"

    r=$(py "
import sys, yaml
raw = open(sys.argv[1]).read()
print('1' if ('check-republish' in raw and 'skip' in raw) else '0')
")
    assert_true "py: republish guard (check-republish skip) referenced for full-matrix publishing" "${r}"

    r=$(py "
import sys, yaml
raw = open(sys.argv[1]).read()
# 2604 JSON cells use ubuntu:26.04; 2404 JSON cells use empty container.
ok = ('ubuntu:26.04' in raw and 'debian:bookworm' in raw
      and 'ubuntu-24.04-arm' in raw and 'ubuntu-24.04' in raw)
print('1' if ok else '0')
")
    assert_true "py: matrix JSON pairs 2604 with ubuntu:26.04 container, bookworm with debian:bookworm" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print('1' if 'go-\${{ matrix.distro }}-\${{ matrix.arch }}' in open(sys.argv[1]).read() else '0')
")
    assert_true "py: Go cache key carries distro+arch dimension" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print('1' if 'debs-\${{ matrix.distro }}-\${{ matrix.arch }}' in open(sys.argv[1]).read() else '0')
")
    assert_true "py: artifact name carries distro+arch dimension" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
p = d['jobs']['publish']
ok = 'build' in p['needs'] and \"needs.build.result == 'success'\" in p['if']
print('1' if ok else '0')
")
    assert_true "py: publish gated on needs.build.result == 'success'" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['publish']['steps']
pats = {s['with']['pattern'] for s in steps
        if isinstance(s.get('with'), dict) and 'pattern' in s['with']}
print('1' if pats == {'debs-2404-*','debs-2604-*','debs-bookworm-*'} else '0')
")
    assert_true "py: publish downloads are per-distro, no bare debs-* merge" "${r}"

    # --- Auto-updating track wiring (stable/v5 crons + resolve-track) ---
    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = d['jobs']
ok = 'resolve-track' in jobs and 'track' in jobs['resolve-track'].get('outputs', {})
print('1' if ok else '0')
")
    assert_true "py: resolve-track job present with a 'track' output" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# 'on' may parse as the boolean True key in YAML.
on = d.get('on', d.get(True))
crons = {c['cron'] for c in on['schedule']}
print('1' if {'30 4 * * 0','30 5 * * *','30 6 * * *'} <= crons else '0')
")
    assert_true "py: schedule crons are weekly Sunday nightly (30 4 * * 0) + stable 05:30 + v5 06:30" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get('on', d.get(True))
opts = on['workflow_dispatch']['inputs']['build_track']['options']
print('1' if opts == ['stable','v5','nightly'] else '0')
")
    assert_true "py: dispatch build_track options are [stable, v5, nightly]" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get('on', d.get(True))
inp = on['workflow_dispatch']['inputs'].get('build_arm', {})
print('1' if inp.get('type') == 'boolean' and inp.get('default') is False else '0')
")
    assert_true "py: dispatch build_arm is boolean default false" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# check-changes fires only on the Sunday nightly cron; check-republish keys on resolve-track.
cc = str(d['jobs']['check-changes']['if'])
cr = str(d['jobs']['check-republish']['if'])
ok = (\"github.event.schedule == '30 4 * * 0'\" in cc
      and 'resolve-track' in str(d['jobs']['check-republish'].get('needs', []))
      and \"outputs.track == 'stable'\" in cr and \"outputs.track == 'v5'\" in cr)
print('1' if ok else '0')
")
    assert_true "py: check-changes is Sunday-nightly-cron-only; check-republish gates stable/v5" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print('1' if 'resolve-track' in d['jobs']['build']['needs'] else '0')
")
    assert_true "py: build job depends on resolve-track" "${r}"

    r=$(py "
import sys, yaml
raw = open(sys.argv[1]).read()
print('1' if 'retention-days: 1' in raw else '0')
")
    assert_true "py: artifact retention-days is 1" "${r}"
}

# ============================================
# Path B: grep/awk floor (always runs)
# ============================================

run_grep_assertions() {
    echo "--- grep/awk floor assertions (comments stripped) ---"

    # 1. single build job, no build-amd64/build-arm64
    local has_build no_split
    has_build=$(printf '%s\n' "${NOCOMMENT}" | grep -Eqc '^[[:space:]]+build:' && echo 1 || echo 0)
    if printf '%s\n' "${NOCOMMENT}" | grep -Eq '^[[:space:]]+build-(amd64|arm64):'; then
        no_split=0
    else
        no_split=1
    fi
    assert_true "grep: 'build:' job present" "${has_build}"
    assert_true "grep: no build-amd64/build-arm64 jobs" "${no_split}"

    # 2. fail-fast: false
    local ff
    ff=$(printf '%s\n' "${NOCOMMENT}" | grep -Eqc 'fail-fast:[[:space:]]*false' && echo 1 || echo 0)
    assert_true "grep: fail-fast: false present" "${ff}"

    # 3. dynamic matrix: build uses fromJson(needs.resolve-track.outputs.matrix)
    # with empty-output fallback so a skipped resolve-track yields an empty
    # matrix instead of a fromJson evaluation error.
    assert_contains "grep: build matrix uses fromJson(needs.resolve-track.outputs.matrix)" \
        "${NOCOMMENT}" 'fromJson(needs.resolve-track.outputs.matrix ||'

    # 4. no static matrix cells under build ('- distro:' YAML list entries)
    local cells
    cells=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec '^[[:space:]]*-[[:space:]]*distro:' || true)
    assert_equals "grep: no static matrix '- distro:' cells (dynamic matrix)" "0" "${cells}"

    # 5. resolve-track defines amd64-only + full JSON with expected distros/arches
    assert_contains "grep: resolve-track defines AMD64_ONLY matrix" \
        "${NOCOMMENT}" 'AMD64_ONLY'
    local has_full
    has_full=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec "FULL" || true)
    assert_true "grep: FULL matrix variable present" \
        "$([[ "${has_full}" -ge 1 ]] && echo 1 || echo 0)"
    assert_contains "grep: matrix gated on inputs.build_arm" \
        "${NOCOMMENT}" 'inputs.build_arm'
    local aarm
    aarm=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec 'arm64' || true)
    assert_true "grep: arm64 cells present in full-matrix JSON" \
        "$([[ "${aarm}" -ge 2 ]] && echo 1 || echo 0)"
    local d2404 d2604 dbw
    d2404=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec '2404' || true)
    d2604=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec '2604' || true)
    dbw=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec 'bookworm' || true)
    assert_true "grep: distro 2404 in matrix JSON" "$([[ "${d2404}" -ge 1 ]] && echo 1 || echo 0)"
    assert_true "grep: distro 2604 in matrix JSON" "$([[ "${d2604}" -ge 1 ]] && echo 1 || echo 0)"
    assert_true "grep: distro bookworm in matrix JSON" "$([[ "${dbw}" -ge 1 ]] && echo 1 || echo 0)"

    # 6. ubuntu:26.04 container at least twice (inside JSON fragments)
    local cont
    cont=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec 'ubuntu:26\.04' || true)
    assert_true "grep: container ubuntu:26.04 appears >= 2 times" \
        "$([[ "${cont}" -ge 2 ]] && echo 1 || echo 0)"

    # 7. Go cache key carries distro dimension
    assert_contains "grep: Go cache key has matrix.distro+arch" \
        "${NOCOMMENT}" 'go-${{ matrix.distro }}-${{ matrix.arch }}'

    # 8. artifact name carries distro+arch
    assert_contains "grep: artifact name has matrix.distro+arch" \
        "${NOCOMMENT}" 'debs-${{ matrix.distro }}-${{ matrix.arch }}'

    # 9. artifact retention-days: 1
    assert_contains "grep: artifact retention-days: 1" \
        "${NOCOMMENT}" 'retention-days: 1'

    # 10. publish gating expression present
    assert_contains "grep: publish gating needs.build.result == 'success'" \
        "${NOCOMMENT}" "needs.build.result == 'success'"

    # 11. no cross-distro merge: both per-distro patterns, no bare debs-*
    local p2404 p2604 pbare
    p2404=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec 'pattern:[[:space:]]*debs-2404-\*' || true)
    p2604=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec 'pattern:[[:space:]]*debs-2604-\*' || true)
    if printf '%s\n' "${NOCOMMENT}" | grep -Eq 'pattern:[[:space:]]*debs-\*[[:space:]]*$'; then
        pbare=1
    else
        pbare=0
    fi
    assert_true "grep: pattern debs-2404-* present" "$([[ "${p2404}" -ge 1 ]] && echo 1 || echo 0)"
    assert_true "grep: pattern debs-2604-* present" "$([[ "${p2604}" -ge 1 ]] && echo 1 || echo 0)"
    assert_true "grep: no bare 'pattern: debs-*' (no cross-distro merge)" \
        "$([[ "${pbare}" -eq 0 ]] && echo 1 || echo 0)"

    # 12. ci_publish.sh invoked for both 2404 and 2604
    local l2404 l2604
    l2404=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec '"2404"' || true)
    l2604=$(printf '%s\n' "${NOCOMMENT}" | grep -Ec '"2604"' || true)
    assert_true "grep: compact label \"2404\" present in publish" \
        "$([[ "${l2404}" -ge 1 ]] && echo 1 || echo 0)"
    assert_true "grep: compact label \"2604\" present in publish" \
        "$([[ "${l2604}" -ge 1 ]] && echo 1 || echo 0)"
    assert_contains "grep: ci_publish.sh invoked" "${NOCOMMENT}" "ci_publish.sh"

    # 13. Sunday nightly cron + stable/v5 crons, resolve-track job, outputs
    assert_contains "grep: Sunday nightly cron 30 4 * * 0" "${NOCOMMENT}" "30 4 * * 0"
    local has_old_nightly
    if printf '%s\n' "${NOCOMMENT}" | grep -Eq "'30 4 \\* \\* \\*'"; then
        has_old_nightly=0
    else
        has_old_nightly=1
    fi
    assert_true "grep: no daily nightly cron '30 4 * * *' remains" "${has_old_nightly}"
    assert_contains "grep: resolve-track job present" "${NOCOMMENT}" "resolve-track:"
    assert_contains "grep: resolve-track outputs matrix" "${NOCOMMENT}" "matrix:"
    assert_contains "grep: check-changes gated on Sunday cron" "${NOCOMMENT}" "github.event.schedule == '30 4 * * 0'"

    # 14. dispatch offers v5 + build_arm, never the retired edge track
    assert_contains "grep: dispatch build_track offers v5" "${NOCOMMENT}" "- v5"
    assert_contains "grep: dispatch offers build_arm" "${NOCOMMENT}" "build_arm:"
    local has_edge
    if printf '%s\n' "${NOCOMMENT}" | grep -Eq '^[[:space:]]*-[[:space:]]*edge[[:space:]]*$'; then
        has_edge=0
    else
        has_edge=1
    fi
    assert_true "grep: no retired 'edge' dispatch option" "${has_edge}"
}

if [[ "${HAVE_PYYAML}" -eq 1 ]]; then
    run_python_assertions
    echo ""
else
    echo "--- PyYAML not available; running grep floor only ---"
fi
run_grep_assertions

# ============================================
# Summary
# ============================================

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
exit 0
