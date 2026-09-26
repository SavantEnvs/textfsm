#!/usr/bin/env bash
#
# mayhem/build.sh — build the textfsm Atheris fuzz harness (compiled launcher.c ELF wrapper that
# execs the system python3 on mayhem/fuzz_fsm.py) and the test oracle.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
#
# A PyInstaller-bundled onefile ELF records edges_covered in Mayhem's cloud fuzzing UI, but its
# bootloader fork/exec chain hides a Python-level "uncaught exception -> libFuzzer target exited"
# crash from Mayhem's regression-replay crash detector (verified: 14/14 known crashers reproduce
# locally but the cloud regression run reported 0 defects). A thin launcher.c that execvp()s the
# system python3 directly keeps the crash in the SAME traced process Mayhem invoked, so its replay
# correctly recognizes it (matches the working pattern in savantenvs/python-libnmap and
# savantenvs/python-fitparse). It records 0 edges in the live cloud UI — irrelevant for a backport,
# whose regression-only replay reports 0 edges either way (BACKPORT.md, Known problems).
#
# AIR-GAPPED CONTRACT (SPEC §6.2 item 9 / §6.5): the PATCH tier re-runs THIS script OFFLINE.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We only need
# DEBUG_FLAGS here (launcher.c is a thin C exec wrapper — sanitizing it would just instrument the
# wrapper, not the fuzzed Python; Atheris instruments the textfsm library itself at import time).

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# 1) Wheelhouse: download atheris ONCE (online). On the air-gapped re-run the directory is already
#    populated, so pip never reaches the network. atheris ships a prebuilt manylinux wheel.
if ls "$WHEELHOUSE"/atheris-*.whl >/dev/null 2>&1; then
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
else
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" atheris
fi

# 2) Install atheris into the fixed site dir, OFFLINE from the wheelhouse. textfsm itself stays the
#    editable source tree (repo root on PYTHONPATH) so a PATCH agent's edits under textfsm/ take
#    effect with no reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$SITE','atheris*')) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" atheris
fi

PYRUN="$SITE:$SRC"

cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, textfsm; print("imports OK: textfsm", textfsm.__version__)'

# 3) Compile the ELF launcher target (DWARF < 4 via $DEBUG_FLAGS). PYTHONPATH is baked into the
#    binary itself (setenv in launcher.c) so it is self-contained regardless of the caller's env.
#    The same binary IS the standalone reproducer: atheris/libFuzzer replays a single input once
#    when given one file argument (no fuzzing loop).
echo ">> compiling fuzz-fsm launcher with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS \
  -DPYTHON="\"$PY\"" \
  -DHARNESS="\"$SRC/mayhem/fuzz_fsm.py\"" \
  -DPYTHONPATH_STR="\"$PYRUN\"" \
  "$SRC/mayhem/launcher.c" -o "$SRC/mayhem/fuzz-fsm-launcher"
install -m 0755 "$SRC/mayhem/fuzz-fsm-launcher" /mayhem/fuzz-fsm

# 4) ELF test runner (anti-reward-hack sabotage requires a non-system binary)
echo ">> compiling run_tests ELF test runner"
$CC $DEBUG_FLAGS \
  -DPYTHON="\"$PY\"" \
  -DTESTS_DIR="\"$SRC/tests/\"" \
  "$SRC/mayhem/run_tests.c" \
  -o "$SRC/run_tests"
chmod +x "$SRC/run_tests"

echo ">> build.sh complete"
ls -la /mayhem/fuzz-fsm "$SRC/run_tests"
