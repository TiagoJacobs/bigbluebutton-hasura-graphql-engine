#!/usr/bin/env bash

# Automated build script for Hasura v2 on release/v2.48.
# - installs system deps (Debian/Ubuntu)
# - ensures GHC 9.10.2 + cabal via ghcup
# - builds engine and tests using the CI-compatible cabal config
#
# Usage:
#   ./build-v2.sh              # Full build with dependencies
#   ./build-v2.sh deps         # Install dependencies only (for CI caching)
#   ./build-v2.sh build        # Build only (skip deps, assumes they're installed)
#   ./build-v2.sh --skip-deps  # Legacy alias for 'build'

set -euo pipefail

ROOT_DIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

export PATH="$HOME/.ghcup/bin:$PATH"
GHC_VERSION="9.10.2"

# Parse command line arguments
MODE="all"
for arg in "$@"; do
  case $arg in
    deps)
      MODE="deps"
      shift
      ;;
    build)
      MODE="build"
      shift
      ;;
    --skip-deps)
      MODE="build"
      shift
      ;;
    *)
      ;;
  esac
done

# Default to the CI "nofreeze" config, which matches CI settings but pins Cabal 3.10.x
# (avoids the pretty-simple/Cabal 3.12 constraint clash in cabal/ci.project.freeze).
CABAL_CONFIG="${CABAL_CONFIG:-cabal/ci-nofreeze.project}"
CABAL_FREEZE="${CABAL_FREEZE:-cabal/ci-nofreeze.project.freeze}"

# If the nofreeze files are missing (e.g. working from a shallow checkout), derive them
# from the main CI config by downgrading the Cabal library constraint.
CABAL_BASE_CONFIG="cabal/ci.project"
CABAL_BASE_FREEZE="cabal/ci.project.freeze"
CABAL_PINNED_LIB_VERSION="3.10.3.0"

ensure_cabal_files() {
  echo "==> Preparing cabal config (${CABAL_CONFIG})"
  if [[ -f "${CABAL_CONFIG}" && -f "${CABAL_FREEZE}" ]]; then
    return
  fi

  if [[ ! -f "${CABAL_BASE_CONFIG}" || ! -f "${CABAL_BASE_FREEZE}" ]]; then
    echo "Missing base cabal config (${CABAL_BASE_CONFIG}) or freeze (${CABAL_BASE_FREEZE})." >&2
    exit 1
  fi

  mkdir -p "$(dirname "${CABAL_CONFIG}")"

  if [[ ! -f "${CABAL_CONFIG}" ]]; then
    cp "${CABAL_BASE_CONFIG}" "${CABAL_CONFIG}"
    # Add allow-newer for pretty-simple:Cabal to work around setup script Cabal version requirement
    cat >> "${CABAL_CONFIG}" <<'EOF'

-- Work around pretty-simple setup dependency requiring Cabal >=3.12
allow-newer: pretty-simple:Cabal
constraints: pretty-simple:setup.Cabal >= 3.12
EOF
  fi

  if [[ ! -f "${CABAL_FREEZE}" ]]; then
    cp "${CABAL_BASE_FREEZE}" "${CABAL_FREEZE}"
    # Don't pin Cabal/Cabal-syntax at all since pretty-simple needs >=3.12 for setup
    # Just remove the Cabal constraints entirely from the freeze file
    perl -0pi -e "s/constraints: any\\.Cabal ==[^\n]+,\n\\s+any\\.Cabal-syntax ==[^\n]+,/constraints: /" "${CABAL_FREEZE}"
    # Remove pretty-simple:setup.Cabal constraint if it exists
    perl -pi -e "s/^\\s*pretty-simple:setup\\.Cabal ==.*\n//" "${CABAL_FREEZE}"
    # Upgrade postgresql-libpq to 0.11.0.0 for Cabal 3.12 SymbolicPath compatibility
    perl -pi -e "s/any\\.postgresql-libpq ==0\\.10\\.1\\.0/any.postgresql-libpq ==0.11.0.0/" "${CABAL_FREEZE}"
    # Remove cabal-doctest pin entirely - let cabal resolve a compatible version for Cabal 3.12
    perl -pi -e "s/^\\s*any\\.cabal-doctest ==.*,?\n//" "${CABAL_FREEZE}"
  fi
}

install_deps() {
  echo "==> Installing system dependencies (requires sudo if not root)"
  if command -v apt-get >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential curl libpq-dev libssl-dev zlib1g-dev unixodbc-dev ca-certificates \
      libgmp-dev libffi-dev libncurses-dev libtinfo6 pkg-config fd-find
    # fd binary name differs on Debian/Ubuntu; ensure `fd` exists for later discovery
    if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
      sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    fi
  else
    echo "apt-get not found; install build tools, libpq-dev, libssl-dev, zlib1g-dev, unixodbc-dev manually." >&2
  fi

  echo "==> Ensuring ghcup is installed"
  if ! command -v ghcup >/dev/null 2>&1; then
    BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_MINIMAL=1 \
      curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
    export PATH="$HOME/.ghcup/bin:$PATH"
  fi

  echo "==> Ensuring GHC ${GHC_VERSION}"
  ghcup install ghc "${GHC_VERSION}" >/dev/null 2>&1 || true
  ghcup set ghc "${GHC_VERSION}"

  echo "==> Ensuring cabal"
  if ! command -v cabal >/dev/null 2>&1; then
    ghcup install cabal 3.10.1.0
  fi

  ensure_cabal_files

  echo "==> Updating cabal index"
  cabal update

  echo "==> Dependencies installed successfully"
}

do_build() {
  echo "==> Ensuring server/CURRENT_VERSION"
  VERSION_FILE="$ROOT_DIR/server/CURRENT_VERSION"
  if [[ ! -f "$VERSION_FILE" ]]; then
    # Prefer an explicit env override, otherwise fall back to the latest tag or commit.
    VERSION_VALUE="${HASURA_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)}"
    echo "$VERSION_VALUE" > "$VERSION_FILE"
  fi

  echo "==> Building graphql-engine and tests"
  CABAL_JOBS="${CABAL_JOBS:-2}"
  cabal build -j"${CABAL_JOBS}" --project-file="${CABAL_CONFIG}" graphql-engine graphql-engine-tests

  ENGINE_BIN=$(fd -g graphql-engine -E '*tests*' dist-newstyle/build | head -n1)
  TEST_BIN=$(fd -g graphql-engine-tests dist-newstyle/build | head -n1)

  echo "Build complete."
  echo "Engine binary: ${ENGINE_BIN}"
  echo "Test binary:   ${TEST_BIN}"
}

case "$MODE" in
  deps)
    install_deps
    ;;
  build)
    echo "==> Skipping dependencies (build mode)"
    ensure_cabal_files
    do_build
    ;;
  all)
    install_deps
    do_build
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: $0 [deps|build|--skip-deps]" >&2
    exit 1
    ;;
esac
