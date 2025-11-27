#!/usr/bin/env bash

# Automated build script for Hasura v2 on release/v2.48.
# - installs system deps (Debian/Ubuntu) when desired
# - ensures GHC 9.10.2 + cabal via ghcup (or uses existing cabal/ghc)
# - prepares CI-specific cabal config (cabal/ci-nofreeze.*)
# - builds engine + tests
#
# Usage (modes):
#   ./scripts/build-v2.sh                # same as "all"
#   ./scripts/build-v2.sh deps           # install toolchain + cabal files only
#   ./scripts/build-v2.sh build          # build only (assumes deps & cabal files)
#   ./scripts/build-v2.sh all            # deps + build
#   ./scripts/build-v2.sh cabal-files    # only (re)generate ci-nofreeze files
#   ./scripts/build-v2.sh clean          # clean dist + generated files
#
# Common flags:
#   --ci                    # CI-friendly mode (less magic, no sudo prompt noise)
#   --local                 # explicitly local dev mode (default)
#   --no-system-deps        # skip apt-get (good on CI or non-Debian systems)
#   --no-cabal-update       # skip 'cabal update'
#   --ghc VERSION           # override GHC version (default: 9.10.2)
#   --jobs N                # override CABAL_JOBS (default: env or 2)
#   --force-cabal-files     # regenerate cabal/ci-nofreeze.project{,.freeze} even if present
#
# Backwards-compatible:
#   ./scripts/build-v2.sh deps
#   ./scripts/build-v2.sh build
#   ./scripts/build-v2.sh --skip-deps   # alias for "build"

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

export PATH="$HOME/.ghcup/bin:$PATH"

# Defaults (can be overridden by flags or env)
GHC_VERSION_DEFAULT="9.10.2"
GHC_VERSION="${GHC_VERSION:-$GHC_VERSION_DEFAULT}"
CABAL_VERSION_DEFAULT="3.10.1.0"
CABAL_JOBS="${CABAL_JOBS:-2}"

MODE="all"
CI_MODE=0
LOCAL_MODE=1
INSTALL_SYSTEM_DEPS=1
RUN_CABAL_UPDATE=1
USE_GHCUP=1
FORCE_CABAL_FILES=0

CABAL_CONFIG="${CABAL_CONFIG:-cabal/ci-nofreeze.project}"
CABAL_FREEZE="${CABAL_FREEZE:-cabal/ci-nofreeze.project.freeze}"
CABAL_BASE_CONFIG="cabal/ci.project"
CABAL_BASE_FREEZE="cabal/ci.project.freeze"

# ---------- Argument parsing ----------

print_usage() {
  cat <<EOF
Usage: $0 [MODE] [FLAGS]

Modes (one of):
  deps           Install toolchain + cabal/ci-nofreeze.* (no build)
  build          Build graphql-engine + tests (no deps)
  all            deps + build (default)
  cabal-files    Only (re)generate cabal/ci-nofreeze.* from cabal/ci.project*
  clean          Remove dist-newstyle, ci-nofreeze files, server/CURRENT_VERSION

Backwards-compatible aliases:
  --skip-deps    Same as "build"

Flags:
  --ci                   CI mode (no interactive assumptions)
  --local                Local dev mode (default)
  --no-system-deps       Do not run apt-get (toolchain assumed present)
  --no-cabal-update      Do not run 'cabal update'
  --ghc VERSION          Use specific GHC version (default: ${GHC_VERSION_DEFAULT})
  --jobs N               Override CABAL_JOBS (default: ${CABAL_JOBS})
  --force-cabal-files    Regenerate cabal/ci-nofreeze.* even if already present

Examples:
  $0 deps --ci --no-system-deps
  $0 build --jobs 8
  $0 all --ghc 9.10.2
  $0 cabal-files --force-cabal-files
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    deps|build|all|cabal-files|clean)
      MODE="$1"
      shift
      ;;
    --skip-deps)
      MODE="build"
      shift
      ;;
    --ci)
      CI_MODE=1
      LOCAL_MODE=0
      shift
      ;;
    --local)
      LOCAL_MODE=1
      CI_MODE=0
      shift
      ;;
    --no-system-deps)
      INSTALL_SYSTEM_DEPS=0
      shift
      ;;
    --no-cabal-update)
      RUN_CABAL_UPDATE=0
      shift
      ;;
    --ghc)
      GHC_VERSION="${2:?--ghc requires a version}"
      shift 2
      ;;
    --jobs)
      CABAL_JOBS="${2:?--jobs requires a number}"
      shift 2
      ;;
    --force-cabal-files)
      FORCE_CABAL_FILES=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

# ---------- Helpers ----------

log() {
  echo "==> $*"
}

ensure_cabal_files() {
  log "Preparing cabal config (${CABAL_CONFIG})"

  if [[ $FORCE_CABAL_FILES -eq 1 ]]; then
    rm -f "${CABAL_CONFIG}" "${CABAL_FREEZE}" || true
  fi

  if [[ -f "${CABAL_CONFIG}" && -f "${CABAL_FREEZE}" ]]; then
    log "cabal/ci-nofreeze.* already present"
    return
  fi

  if [[ ! -f "${CABAL_BASE_CONFIG}" || ! -f "${CABAL_BASE_FREEZE}" ]]; then
    echo "Missing base cabal config (${CABAL_BASE_CONFIG}) or freeze (${CABAL_BASE_FREEZE})." >&2
    exit 1
  fi

  mkdir -p "$(dirname "${CABAL_CONFIG}")"

  # Config file
  if [[ ! -f "${CABAL_CONFIG}" ]]; then
    cp "${CABAL_BASE_CONFIG}" "${CABAL_CONFIG}"
    # Work around pretty-simple setup dependency requiring Cabal >=3.12
    cat >> "${CABAL_CONFIG}" <<'EOF'

-- Work around pretty-simple setup dependency requiring Cabal >=3.12
allow-newer: pretty-simple:Cabal
constraints: pretty-simple:setup.Cabal >= 3.12
EOF
  fi

  # Freeze file
  if [[ ! -f "${CABAL_FREEZE}" ]]; then
    cp "${CABAL_BASE_FREEZE}" "${CABAL_FREEZE}"
    # Remove Cabal / Cabal-syntax pins to allow newer Cabal for pretty-simple
    perl -0pi -e "s/constraints: any\\.Cabal ==[^\n]+,\n\\s+any\\.Cabal-syntax ==[^\n]+,/constraints: /" "${CABAL_FREEZE}"
    # Remove pretty-simple:setup.Cabal constraint if it exists
    perl -pi -e "s/^\\s*pretty-simple:setup\\.Cabal ==.*\n//" "${CABAL_FREEZE}"
    # Bump postgresql-libpq for Cabal 3.12 SymbolicPath compatibility
    perl -pi -e "s/any\\.postgresql-libpq ==0\\.10\\.1\\.0/any.postgresql-libpq ==0.11.0.0/" "${CABAL_FREEZE}"
    # Remove cabal-doctest pin entirely
    perl -pi -e "s/^\\s*any\\.cabal-doctest ==.*,?\n//" "${CABAL_FREEZE}"
  fi

  log "cabal/ci-nofreeze.project and .freeze ready"
}

install_deps() {
  log "Installing build dependencies"

  if [[ $INSTALL_SYSTEM_DEPS -eq 1 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      log "Installing system packages via apt-get"
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential curl libpq-dev libssl-dev zlib1g-dev unixodbc-dev ca-certificates \
        libgmp-dev libffi-dev libncurses-dev libtinfo6 pkg-config fd-find
      # fd binary name differs on Debian/Ubuntu; ensure `fd` exists
      if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
        sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
      fi
    else
      echo "apt-get not found; please install build tools, libpq-dev, libssl-dev, zlib1g-dev, unixodbc-dev, etc manually." >&2
    fi
  else
    log "Skipping system package installation (--no-system-deps)"
  fi

  if [[ $USE_GHCUP -eq 1 ]]; then
    log "Ensuring ghcup is installed"
    if ! command -v ghcup >/dev/null 2>&1; then
      BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_MINIMAL=1 \
        curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
      export PATH="$HOME/.ghcup/bin:$PATH"
    fi

    log "Ensuring GHC ${GHC_VERSION}"
    ghcup install ghc "${GHC_VERSION}" >/dev/null 2>&1 || true
    ghcup set ghc "${GHC_VERSION}"

    log "Ensuring cabal"
    if ! command -v cabal >/dev/null 2>&1; then
      ghcup install cabal "${CABAL_VERSION_DEFAULT}"
    fi
  else
    log "Skipping ghcup (USE_GHCUP=0) - assuming ghc+cabal are already available"
    if ! command -v cabal >/dev/null 2>&1; then
      echo "cabal not found, but USE_GHCUP=0. Please install cabal or enable ghcup." >&2
      exit 1
    fi
  fi

  ensure_cabal_files

  if [[ $RUN_CABAL_UPDATE -eq 1 ]]; then
    log "Updating cabal index"
    cabal update
  else
    log "Skipping 'cabal update' (--no-cabal-update)"
  fi

  log "Dependencies installed successfully"
}

ensure_version_file() {
  log "Ensuring server/CURRENT_VERSION"
  local version_file="$ROOT_DIR/server/CURRENT_VERSION"
  if [[ ! -f "$version_file" ]]; then
    local version_value
    version_value="${HASURA_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)}"
    echo "$version_value" > "$version_file"
  fi
}

do_build() {
  log "Starting build (jobs: ${CABAL_JOBS}, project: ${CABAL_CONFIG})"

  ensure_cabal_files
  ensure_version_file

  cabal build -j"${CABAL_JOBS}" --project-file="${CABAL_CONFIG}" \
    graphql-engine graphql-engine-tests

  local engine_bin test_bin
  engine_bin=$(fd -g graphql-engine -E '*tests*' dist-newstyle/build | head -n1 || true)
  test_bin=$(fd -g graphql-engine-tests dist-newstyle/build | head -n1 || true)

  echo "Build complete."
  echo "Engine binary: ${engine_bin:-<not found>}"
  echo "Test binary:   ${test_bin:-<not found>}"
}

do_clean() {
  log "Cleaning build artifacts"
  rm -rf dist-newstyle
  rm -f cabal/ci-nofreeze.project cabal/ci-nofreeze.project.freeze
  rm -f server/CURRENT_VERSION
  log "Clean complete"
}

# ---------- Main dispatch ----------

case "$MODE" in
  deps)
    install_deps
    ;;
  build)
    log "Build mode (skipping dependency installation)"
    # still ensure cabal files exist
    ensure_cabal_files
    do_build
    ;;
  all)
    install_deps
    do_build
    ;;
  cabal-files)
    ensure_cabal_files
    ;;
  clean)
    do_clean
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    print_usage
    exit 1
    ;;
esac

