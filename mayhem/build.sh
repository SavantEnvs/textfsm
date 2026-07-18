#!/usr/bin/env bash
#
# mayhem/build.sh — build the textfsm Atheris fuzz harness (PyInstaller onefile ELF) and test oracle.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
#
# PyInstaller bundles Python+atheris into one ELF so Mayhem can collect edges_covered (>0).
# A thin C launcher that execs python3 fuzzes locally but records 0 edges in Mayhem cloud.
#
# AIR-GAPPED CONTRACT (SPEC §6.2 item 9 / §6.5): the PATCH tier re-runs THIS script OFFLINE.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
PY="$(command -v python3)"

# PyInstaller onefile lacks .debug_info; graft DWARF-3 sections from a compiled anchor (§6.2 item 10).
graft_dwarf() {
  local bin="$1"
  # shellcheck disable=SC2086
  $CC -c $DEBUG_FLAGS "$SRC/mayhem/asan_defaults.c" -o /tmp/dwarf_anchor.o
  for sect in .debug_info .debug_abbrev .debug_line .debug_str; do
    if objcopy --dump-section "${sect}=/tmp/dwarf_sect.bin" /tmp/dwarf_anchor.o 2>/dev/null; then
      objcopy --add-section "${sect}=/tmp/dwarf_sect.bin" \
        --set-section-flags "${sect}=alloc,merge,debug" "$bin" /tmp/bin_grafted
      mv /tmp/bin_grafted "$bin"
    fi
  done
}

# ── 1) Wheelhouse (online first pass; offline re-run) ───────────────────────────────────
mkdir -p "$WHEELHOUSE"
if ls "$WHEELHOUSE"/atheris-*.whl >/dev/null 2>&1 && ls "$WHEELHOUSE"/pyinstaller-*.whl >/dev/null 2>&1; then
  echo ">> wheelhouse already populated — reusing (air-gapped re-run path)"
else
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" atheris pyinstaller
fi

# ── 2) Test oracle: clean venv (no sanitizers) ──────────────────────────────────────────
if [ -x /mayhem/test-venv/bin/python3 ] && /mayhem/test-venv/bin/python3 -c "import textfsm" 2>/dev/null; then
  echo ">> test venv already ready — skipping"
else
  echo ">> installing textfsm for test oracle (clean)"
  python3 -m venv /mayhem/test-venv
  /mayhem/test-venv/bin/pip install --upgrade pip setuptools wheel
  (
    unset CFLAGS CXXFLAGS LDFLAGS
    /mayhem/test-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" . 2>/dev/null \
      || /mayhem/test-venv/bin/pip install .
  )
fi

# ── 3) Fuzz build: atheris + PyInstaller onefile ELF (bitstruct pattern) ────────────────
if [ -x /mayhem/fuzz-fsm ] && /mayhem/fuzz-venv/bin/python3 -c "import atheris" 2>/dev/null; then
  echo ">> fuzz-fsm ELF already built — skipping PyInstaller (idempotent re-run)"
else
  echo ">> building fuzz-fsm PyInstaller ELF"
  python3 -m venv /mayhem/fuzz-venv
  /mayhem/fuzz-venv/bin/pip install --upgrade pip setuptools wheel
  export CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS"
  /mayhem/fuzz-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" atheris pyinstaller 2>/dev/null \
    || /mayhem/fuzz-venv/bin/pip install atheris pyinstaller
  /mayhem/fuzz-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" . 2>/dev/null \
    || /mayhem/fuzz-venv/bin/pip install .

  # shellcheck disable=SC2086
  $CC -shared -fPIC $DEBUG_FLAGS -o /mayhem/asan_defaults.so "$SRC/mayhem/asan_defaults.c"

  /mayhem/fuzz-venv/bin/pyinstaller \
    --distpath /tmp/pyinst-out \
    --workpath /tmp/pyinst-work \
    --specpath /tmp/pyinst-spec \
    --onefile \
    --name fuzz-fsm \
    --paths "$SRC/mayhem" \
    --collect-all textfsm \
    --hidden-import fuzz_helpers \
    --hidden-import six \
    --add-binary /mayhem/asan_defaults.so:. \
    "$SRC/mayhem/fuzz_fsm.py"

  install -m 0755 /tmp/pyinst-out/fuzz-fsm /mayhem/fuzz-fsm
  graft_dwarf /mayhem/fuzz-fsm
fi

# ── 4) ELF test runner (anti-reward-hack sabotage requires a non-system binary) ─────────
if [ -x "$SRC/run_tests" ]; then
  echo ">> run_tests already built — skipping"
else
  echo ">> compiling run_tests ELF test runner"
  # shellcheck disable=SC2086
  $CC -c $DEBUG_FLAGS "$SRC/mayhem/asan_defaults.c" -o /tmp/asan_defaults.o
  # shellcheck disable=SC2086
  $CC $DEBUG_FLAGS \
    -DPYTHON="\"/mayhem/test-venv/bin/python3\"" \
    -DTESTS_DIR="\"$SRC/tests/\"" \
    "$SRC/mayhem/run_tests.c" /tmp/asan_defaults.o \
    -o "$SRC/run_tests"
  chmod +x "$SRC/run_tests"
fi

echo ">> build.sh complete"
ls -la /mayhem/fuzz-fsm "$SRC/run_tests"
