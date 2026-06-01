#!/usr/bin/env bash
# =============================================================================
# install_deps.sh
# =============================================================================
#
# Installs and validates all dependencies required by verify_build.sh.
#
# Responsibilities:
#   - Install required system tools
#   - Install pinned toolchain components
#   - Configure Nix with flakes enabled
#   - Create a Python virtual environment
#   - Install pinned Python dependencies
#   - Clone and refresh source repositories
#   - Configure cross-architecture builds when required
#
# Each dependency is reported as:
#   OK      already present and suitable
#   FIXED   installed or updated by this script
#   MANUAL  requires user intervention
#
# Run as a normal user. Administrative privileges are used only when
# required for package installation or system configuration.
#
# Optional environment variables:
#   MODELS=a,b
#   GO_VERSION=...
#   NO_CLONE=1
#   VENV_DIR=...
# =============================================================================

set -uo pipefail

GO_VERSION="${GO_VERSION:-1.25.3}"   # match the project's pinned toolchain
GH_MIN="${GH_MIN:-2.67.0}"           # minimum gh with `attestation verify`
GH_VERSION="${GH_VERSION:-2.67.0}"   # version to fetch if gh is too old
SNP_PIN="0.0.12"                     # exact; pinned by measure-image-action
MODELS="${MODELS:-kimi-k2-6}"        # which confidential-<model> repos
NO_CLONE="${NO_CLONE:-0}"            # set 1 to skip cloning the repos

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Place the virtual environment on a local filesystem. Some shared or
# virtualized filesystems do not support the features required by venv.
VENV="${VENV_DIR:-$HOME/.maple-verify/venv}"
VLOG="${TMPDIR:-/tmp}/maple-venv.$$.log"

R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
C=$'\033[0;36m'; B=$'\033[1m'; Z=$'\033[0m'
declare -A ST
ok(){   ST["$1"]=OK;     echo "${G}[OK]${Z}     $1${2:+ - $2}"; }
fix(){  ST["$1"]=FIXED;  echo "${G}[FIXED]${Z}  $1${2:+ - $2}"; }
man(){  ST["$1"]=MANUAL; echo "${R}[MANUAL]${Z} $1${2:+ - $2}"; }
inf(){  echo "${C}[..]${Z}     $*"; }
sec(){  echo; echo "${B}=== $* ===${Z}"; }
have(){ command -v "$1" >/dev/null 2>&1; }
# true if version $1 >= version $2
ver_ge(){ [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# ---- privilege -------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then SUDO=""
elif have sudo;               then SUDO="sudo"
else SUDO=""; inf "not root and no sudo: installs will be MANUAL"; fi

# ---- OS / arch -------------------------------------------------------------
OS="$(uname -s)"; M="$(uname -m)"
case "$M" in
  x86_64|amd64)  GOA=amd64; GHA=amd64 ;;
  aarch64|arm64) GOA=arm64; GHA=arm64 ;;
  *) GOA=""; GHA=""; inf "unusual arch $M: go/gh tarballs may not match" ;;
esac
case "$OS" in
  Linux)  GOOS=linux;  GHOS=linux ;;
  Darwin) GOOS=darwin; GHOS=macOS ;;
  *) inf "unsupported OS $OS"; ;;
esac
inf "host: $OS/$M. PCR measurements are architecture-specific."

# ---- package-manager abstraction ------------------------------------------
PM=""
for c in apt-get dnf yum pacman zypper apk brew; do
  have "$c" && { PM="$c"; break; }
done
inf "package manager: ${PM:-none detected}"

# pmi <logical>...   install ubiquitous tools by logical name
pmi(){
  local pkgs=() p
  for p in "$@"; do
    case "$PM:$p" in
      apt-get:python3) pkgs+=(python3 python3-venv python3-pip) ;;
      *:python3)       pkgs+=(python3 python3-pip) ;;
      *)               pkgs+=("$p") ;;
    esac
  done
  case "$PM" in
    apt-get) $SUDO apt-get update -qq && \
             $SUDO apt-get install -y "${pkgs[@]}" ;;
    dnf)     $SUDO dnf install -y "${pkgs[@]}" ;;
    yum)     $SUDO yum install -y "${pkgs[@]}" ;;
    pacman)  $SUDO pacman -Sy --noconfirm "${pkgs[@]}" ;;
    zypper)  $SUDO zypper -n install "${pkgs[@]}" ;;
    apk)     $SUDO apk add "${pkgs[@]}" ;;
    brew)    brew install "${pkgs[@]}" ;;
    *)       return 1 ;;
  esac
}

# ---- ubiquitous tools ------------------------------------------------------
sec "Core tools (curl, jq, git, python3)"
for t in curl jq git; do
  if have "$t"; then ok "$t"
  elif pmi "$t" >/dev/null 2>&1 && have "$t"; then fix "$t"
  else man "$t" "install '$t' with your package manager"; fi
done
have python3 || pmi python3 >/dev/null 2>&1
if have python3; then
  ok "python3" "$(python3 -V 2>&1 | awk '{print $2}')"
else
  man "python3" "install python3 (+venv,+pip)"
fi
# Verify that the venv and pip components are available. Some
# distributions package them separately from python3 itself.
if have python3 && ! python3 -c 'import ensurepip' 2>/dev/null; then
  case "$PM" in
    apt-get) $SUDO apt-get install -y \
               python3-venv python3-pip python3-full >/dev/null 2>&1 ;;
    *)       pmi python3 >/dev/null 2>&1 ;;
  esac
  if python3 -c 'import ensurepip' 2>/dev/null; then
    fix "python3-venv" "installed"
  else
    man "python3-venv" "install the venv package for your distro"
  fi
fi

# ---- container runtime (docker OR podman; either is fine) -----------------
sec "Container runtime"
if have docker || have podman; then
  ok "container" "$(have docker && echo docker || echo podman)"
elif pmi podman >/dev/null 2>&1 && have podman; then
  fix "container" "podman"
else
  man "container" "install docker or podman"
fi
# Ensure Podman can resolve unqualified image names.
if have podman && ! have docker; then
  rc=/etc/containers/registries.conf
  if ! grep -qs 'unqualified-search-registries' "$rc" 2>/dev/null; then
    $SUDO mkdir -p /etc/containers
    echo 'unqualified-search-registries = ["docker.io"]' \
      | $SUDO tee -a "$rc" >/dev/null \
      && inf "added docker.io to $rc (fixes A1 podman short-name error)"
  fi
fi

# ---- Go (reproducible build toolchain) -------------------------------------
sec "Go toolchain (pinned $GO_VERSION)"
GOCUR="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
if [[ "$GOCUR" == "$GO_VERSION" ]]; then
  ok "go" "$GO_VERSION"
elif [[ -z "$GOA" || -z "$SUDO" && "$(id -u)" -ne 0 ]]; then
  man "go" "install go $GO_VERSION from https://go.dev/dl/"
else
  [[ -n "$GOCUR" ]] && inf "found go $GOCUR; replacing with pinned \
$GO_VERSION"
  tgz="go${GO_VERSION}.${GOOS}-${GOA}.tar.gz"
  if curl -fsSL "https://go.dev/dl/${tgz}" -o "/tmp/${tgz}"; then
    $SUDO rm -rf /usr/local/go
    $SUDO tar -C /usr/local -xzf "/tmp/${tgz}"
    if [[ "$OS" == Linux ]]; then
      echo 'export PATH="$PATH:/usr/local/go/bin"' \
        | $SUDO tee /etc/profile.d/go.sh >/dev/null
    fi
    export PATH="$PATH:/usr/local/go/bin"
    fix "go" "$GO_VERSION -> /usr/local/go"
  else
    man "go" "could not download $tgz"
  fi
fi

# ---- GitHub CLI (attestation verification) ---------------------------------
sec "GitHub CLI (>= $GH_MIN, for Sigstore provenance)"
GHCUR="$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
if [[ -n "$GHCUR" ]] && ver_ge "$GHCUR" "$GH_MIN"; then
  ok "gh" "$GHCUR"
else
  [[ -n "$GHCUR" ]] && inf "found gh $GHCUR (< $GH_MIN); upgrading"
  done_gh=false
  # Try the package manager first; accept only if it meets the minimum.
  if [[ -z "$GHCUR" ]] && pmi gh >/dev/null 2>&1 && have gh; then
    GHCUR="$(gh --version | head -1 | awk '{print $3}')"
    ver_ge "$GHCUR" "$GH_MIN" && { fix "gh" "$GHCUR (pkg)"; done_gh=true; }
  fi
  if ! $done_gh && [[ -n "$GHA" ]]; then
    tb="gh_${GH_VERSION}_${GHOS}_${GHA}.tar.gz"
    url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tb}"
    if curl -fsSL "$url" -o "/tmp/${tb}"; then
      tar -C /tmp -xzf "/tmp/${tb}"
      $SUDO install -m 0755 \
        "/tmp/gh_${GH_VERSION}_${GHOS}_${GHA}/bin/gh" /usr/local/bin/gh
      have gh && { fix "gh" "$GH_VERSION -> /usr/local/bin/gh";
                   done_gh=true; }
    fi
  fi
  $done_gh || man "gh" "install gh >= $GH_MIN from github.com/cli/cli"
fi

# ---- Nix (hermetic build environment) --------------------------------------
sec "Nix (hermetic builds: continuum-proxy + the EIF)"
if have nix; then
  ok "nix" "$(nix --version 2>/dev/null | awk '{print $3}')"
elif [[ "$OS" != Linux && "$OS" != Darwin ]]; then
  man "nix" "unsupported OS for the official installer"
else
  # Install a multi-user Nix configuration with a functioning daemon.
  inf "installing Nix (Determinate multi-user, --no-confirm)"
  if curl --proto '=https' --tlsv1.2 -sSf -L \
       https://install.determinate.systems/nix \
       | sh -s -- install --no-confirm >/dev/null 2>&1 || have nix; then
    fix "nix" "installed (multi-user; open a new shell for PATH)"
  else
    man "nix" "install manually: https://nixos.org/download (multi-user)"
  fi
fi
# Enable flakes support if it is not already configured.
if [[ "$OS" == Linux ]] || have nix; then
  conf=/etc/nix/nix.conf
  if ! grep -qs 'experimental-features.*flakes' "$conf" 2>/dev/null; then
    $SUDO mkdir -p /etc/nix
    echo 'experimental-features = nix-command flakes' \
      | $SUDO tee -a "$conf" >/dev/null && \
      inf "enabled nix flakes in $conf"
  fi
fi
# Ensure the Nix daemon is running and the store is reachable.
if [[ "$OS" == Linux ]] && have nix; then
  $SUDO systemctl enable --now nix-daemon >/dev/null 2>&1 || true
  if [[ -S /nix/var/nix/daemon-socket/socket ]] \
     && NIX_REMOTE=daemon nix store ping >/dev/null 2>&1; then
    ok "nix-daemon" "running; store reachable"
  else
    man "nix-daemon" "daemon not reachable - see remediation below"
    inf "  sudo systemctl enable --now nix-daemon"
    inf "  exec bash -l       # fresh login shell sets NIX_REMOTE"
    inf "  nix store ping     # must succeed before running verify_build.sh"
  fi
fi

# ---- Python environment and pinned dependencies ----------------------------
sec "Python venv (live anchor + SNP recompute)"
inf "venv location: $VENV"
[[ "$ROOT" == /media/sf_* || "$ROOT" == /vagrant* ]] && inf \
  "(script is on a shared folder; venv is OFF it on purpose - vboxsf"
inf "cannot hold a venv.  Override with VENV_DIR=... if needed.)"
if ! have python3; then
  man "python-deps" "python3 missing"
elif [[ -x "$VENV/bin/python" ]]; then
  ok "python-venv" "already at $VENV"
else
  mkdir -p "$(dirname "$VENV")"
  # Use copies rather than symlinks for broader filesystem compatibility.
  if python3 -m venv --copies "$VENV" >"$VLOG" 2>&1; then
    ok "python-venv" "created at $VENV"
  else
    man "python-deps" "venv creation FAILED - real error below:"
    tail -n 8 "$VLOG" | sed 's/^/    /'
    inf "fix: install python3-venv (Debian) OR set VENV_DIR to a path"
    inf "on a native disk (NOT a /media/sf_* shared folder)."
  fi
fi
if [[ -x "$VENV/bin/pip" ]]; then
  "$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1
  "$VENV/bin/pip" install -q 'cryptography>=42' 'cbor2>=5' \
    'requests>=2' 'pyyaml>=6' "sev-snp-measure==${SNP_PIN}" \
    >"$VLOG" 2>&1
  got="$("$VENV/bin/pip" show sev-snp-measure 2>/dev/null \
         | awk '/^Version:/{print $2}')"
  if [[ "$got" == "$SNP_PIN" ]] && "$VENV/bin/python" -c \
       'import cryptography,cbor2,requests,yaml' 2>/dev/null; then
    fix "python-deps" "sev-snp-measure $got + deps in $VENV"
  else
    man "python-deps" "pip install FAILED - real error below:"
    tail -n 8 "$VLOG" | sed 's/^/    /'
  fi
fi

# ---- Source repositories ---------------------------------------------------
# Repositories are cloned at release tags when available.
GH="https://github.com"
latest_tag(){            # $1 = clone url  ->  newest semver-ish tag
  git ls-remote --tags --refs "$1" 2>/dev/null \
    | sed 's#.*refs/tags/##' | grep -E '^v?[0-9]' \
    | sort -V | tail -1
}
clone_at(){              # $1 url  $2 dir  $3 ref(""=latest)  $4 git-extra
  local url="$1" dir="$2" ref="$3" extra="${4:-}"
  if [[ -d "$ROOT/$dir/.git" ]]; then
    # Refresh existing clones and reapply the requested revision.
    # Repositories without release tags follow their default branch.
    ( cd "$ROOT/$dir" && git fetch --quiet --tags --force origin 2>/dev/null )
    local current new_ref
    current="$(git -C "$ROOT/$dir" rev-parse --short HEAD 2>/dev/null)"
    if [[ -z "$ref" ]]; then
      new_ref="$(latest_tag "$url")"
      # Fall back to the default branch when no release tags exist.
      if [[ -z "$new_ref" ]]; then
        local def_branch
        def_branch="$(git -C "$ROOT/$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
                      | sed 's#^origin/##')"
        new_ref="${def_branch:-master}"
        ( cd "$ROOT/$dir" && git checkout --quiet "$new_ref" 2>/dev/null \
                          && git pull --quiet --ff-only origin "$new_ref" 2>/dev/null ) \
          && fix "clone:$dir" "pulled $new_ref (was $current)" \
          || ok  "clone:$dir" "$current (could not fast-forward; local changes?)"
        ( cd "$ROOT/$dir" && git submodule update --init --recursive --quiet ) 2>/dev/null
        return 0
      fi
    else
      new_ref="$ref"
    fi
    if git -C "$ROOT/$dir" checkout --quiet "$new_ref" 2>/dev/null; then
      ( cd "$ROOT/$dir" && git submodule update --init --recursive --quiet ) 2>/dev/null
      fix "clone:$dir" "updated to $new_ref (was $current)"
    else
      ok  "clone:$dir" "$current (could not check out $new_ref)"
    fi
    return 0
  fi
  if ! git clone $extra "$url" "$ROOT/$dir" >/dev/null 2>&1; then
    man "clone:$dir" "git clone failed: $url"; return 1
  fi
  [[ -z "$ref" ]] && ref="$(latest_tag "$url")"
  if [[ -n "$ref" ]] \
     && git -C "$ROOT/$dir" checkout -q "$ref" 2>/dev/null; then
    [[ -n "$extra" ]] && git -C "$ROOT/$dir" submodule update \
      --init --recursive >/dev/null 2>&1
    fix "clone:$dir" "$ref"
  elif [[ -z "$ref" ]]; then
    fix "clone:$dir" "default branch (no release tags found)"
  else
    man "clone:$dir" "cloned but could not checkout tag $ref"
  fi
}

sec "Clone source repositories (release tags, into $ROOT)"
if [[ "$NO_CLONE" == 1 ]]; then
  inf "NO_CLONE=1 set - skipping"
elif ! have git; then
  man "clone" "git missing - cannot clone repos"
else
  # Router configuration repository.
  clone_at "$GH/tinfoilsh/confidential-model-router.git" \
           confidential-model-router ""
  # Model repositories.
  for m in ${MODELS//,/ }; do
    clone_at "$GH/tinfoilsh/confidential-$m.git" \
             "confidential-$m" ""
  done
  # cvmimage at the version referenced by the router configuration.
  rc="$ROOT/confidential-model-router/tinfoil-config.yml"
  CVMV=""
  [[ -f "$rc" ]] && CVMV="$(grep -E '^cvm-version:' "$rc" \
                            | awk '{print $2}')"
  if [[ -n "$CVMV" ]]; then
    clone_at "$GH/tinfoilsh/cvmimage.git" cvmimage "v$CVMV"
  else
    inf "could not read cvm-version; cloning cvmimage at latest tag"
    clone_at "$GH/tinfoilsh/cvmimage.git" cvmimage ""
  fi
  # Report version mismatches between model and router configuration.
  for m in ${MODELS//,/ }; do
    mc="$ROOT/confidential-$m/tinfoil-config.yml"
    [[ -f "$mc" ]] || continue
    mv_="$(grep -E '^cvm-version:' "$mc" | awk '{print $2}')"
    [[ -n "$mv_" && "$mv_" != "$CVMV" ]] && inf \
      "model $m pins cvm-version $mv_ (router $CVMV): \
checkout cvmimage v$mv_ when verifying $m"
  done
  # Measurement tooling.
  clone_at "$GH/tinfoilsh/measure-image-action.git" \
           measure-image-action ""
  # OpenSecret repository and submodules.
  clone_at "$GH/OpenSecretCloud/opensecret.git" opensecret "" \
           "--recurse-submodules"
  inf "opensecret will be auto-aligned to the live deploy by verify_build.sh's A0 step"
  # Auxiliary repository used for binary verification.
  clone_at "$GH/edgelesssys/privatemode-public.git" \
           privatemode-public ""
fi

# ---- Cross-architecture build support --------------------------------------
# Configure emulation and Nix cross-platform support when the host
# architecture differs from the committed binaries.
sec "Cross-arch build setup (QEMU, only when host != committed-binary arch)"

# Detect the architecture of the committed binaries.
COMMITTED_ARCH=""
if [[ -f "$ROOT/opensecret/continuum-proxy" ]] && have file; then
  case "$(file -b "$ROOT/opensecret/continuum-proxy" 2>/dev/null)" in
    *aarch64*|*ARM\ aarch64*) COMMITTED_ARCH="aarch64" ;;
    *x86-64*|*x86_64*)        COMMITTED_ARCH="x86_64"  ;;
  esac
fi
case "$M" in
  arm64) HOST_NIX_ARCH="aarch64" ;;
  amd64) HOST_NIX_ARCH="x86_64"  ;;
  *)     HOST_NIX_ARCH="$M"      ;;
esac
inf "host arch: $HOST_NIX_ARCH"
inf "committed-binary arch: ${COMMITTED_ARCH:-unknown}"

if [[ -z "$COMMITTED_ARCH" ]]; then
  inf "could not detect committed arch (no opensecret/continuum-proxy yet?); skipping QEMU setup"
elif [[ "$COMMITTED_ARCH" == "$HOST_NIX_ARCH" ]]; then
  inf "host arch matches committed-binary arch; no emulation needed"
else
  CROSS_TARGET="${COMMITTED_ARCH}-linux"
  inf "host ($HOST_NIX_ARCH) != committed ($COMMITTED_ARCH); configuring QEMU for $CROSS_TARGET"

  # Select the appropriate QEMU interpreter.
  case "$COMMITTED_ARCH" in
    aarch64) QEMU_BIN="qemu-aarch64-static" ; BINFMT_KEY="aarch64" ;;
    x86_64)  QEMU_BIN="qemu-x86_64-static"  ; BINFMT_KEY="x86_64"  ;;
    *)       QEMU_BIN=""                    ; BINFMT_KEY=""        ;;
  esac

  # Install QEMU user emulation support.
  if [[ "$PM" == "apt-get" ]]; then
    if have "$QEMU_BIN"; then
      ok "qemu-user-static" "already installed ($QEMU_BIN found)"
    elif $SUDO apt-get install -y qemu-user-static binfmt-support \
           >/dev/null 2>&1 && have "$QEMU_BIN"; then
      fix "qemu-user-static" "installed via apt"
    else
      man "qemu-user-static" "install qemu-user-static manually"
    fi
  elif [[ "$PM" == "dnf" || "$PM" == "yum" ]]; then
    if have "$QEMU_BIN"; then
      ok "qemu-user-static" "already installed"
    elif $SUDO "$PM" install -y qemu-user-static >/dev/null 2>&1 \
         && have "$QEMU_BIN"; then
      fix "qemu-user-static" "installed via $PM"
    else
      man "qemu-user-static" "install qemu-user-static manually"
    fi
  else
    man "qemu-user-static" "install qemu-user-static via your package manager"
  fi

  # Verify binfmt registration for the target architecture.
  bf_ok=false
  for f in /proc/sys/fs/binfmt_misc/*${BINFMT_KEY}*; do
    [[ -f "$f" ]] && grep -q '^enabled' "$f" 2>/dev/null && bf_ok=true && break
  done
  if $bf_ok; then
    ok "binfmt-${BINFMT_KEY}" "registered and enabled"
  else
    $SUDO systemctl restart systemd-binfmt >/dev/null 2>&1 || true
    bf_ok=false
    for f in /proc/sys/fs/binfmt_misc/*${BINFMT_KEY}*; do
      [[ -f "$f" ]] && grep -q '^enabled' "$f" 2>/dev/null && bf_ok=true && break
    done
    if $bf_ok; then
      fix "binfmt-${BINFMT_KEY}" "registered after systemd-binfmt restart"
    else
      man "binfmt-${BINFMT_KEY}" \
        "binfmt_misc has no enabled $BINFMT_KEY entry; check 'sudo systemctl status systemd-binfmt'"
    fi
  fi

  # Configure Nix to advertise support for the target architecture.
  # Determinate Nix stores persistent custom settings in nix.custom.conf.
  nc=/etc/nix/nix.conf
  if grep -qiE 'do not modify|will be replaced|!include nix\.custom\.conf' \
       "$nc" 2>/dev/null || [[ -f /etc/nix/nix.custom.conf ]]; then
    nc=/etc/nix/nix.custom.conf
    inf "Determinate Nix detected -> writing to $nc (nix.conf is auto-replaced)"
    [[ -f "$nc" ]] || $SUDO touch "$nc"
  fi
  if grep -qE "^extra-platforms\s*=.*\b${CROSS_TARGET}\b" "$nc" 2>/dev/null; then
    ok "nix:extra-platforms" "$nc already includes $CROSS_TARGET"
    nix_conf_changed=false
  else
    {
      echo
      echo "# Added by install_deps.sh for cross-arch EIF builds ($CROSS_TARGET)"
      echo "extra-platforms = $CROSS_TARGET"
    } | $SUDO tee -a "$nc" >/dev/null && \
      fix "nix:extra-platforms" "added $CROSS_TARGET to $nc" || \
      man "nix:extra-platforms" "manually add 'extra-platforms = $CROSS_TARGET' to $nc"
    nix_conf_changed=true
  fi
  # No additional sandbox configuration is required when binfmt uses
  # fixed interpreters.

  # Reload Nix configuration if it changed.
  if [[ "${nix_conf_changed:-false}" == "true" ]]; then
    if $SUDO systemctl restart nix-daemon >/dev/null 2>&1; then
      fix "nix-daemon" "restarted to load new extra-platforms"
    else
      man "nix-daemon" "manually: sudo systemctl restart nix-daemon"
    fi
  fi

  # Verify that Nix advertises the configured cross-platform target.
  if have nix && { nix config show 2>/dev/null \
                   || nix show-config 2>/dev/null; } \
       | grep -qE "^extra-platforms\b.*\b${CROSS_TARGET}\b"; then
    ok "nix-cross-ready" "Nix advertises extra-platforms = $CROSS_TARGET"
  else
    man "nix-cross-ready" \
      "Nix still does not advertise $CROSS_TARGET - check: nix config show | grep extra-platforms"
  fi
fi

# ---- repo layout check -----------------------------------------------------
sec "Repository layout (must be siblings of this script: $ROOT)"
for d in opensecret privatemode-public cvmimage measure-image-action \
         confidential-model-router; do
  [[ -d "$ROOT/$d" ]] && echo "${G}[OK]${Z}     $d/" \
                       || echo "${Y}[MISS]${Z}   $d/"
done
[[ -f "$ROOT/verify_live_attestation.py" ]] \
  && echo "${G}[OK]${Z}     verify_live_attestation.py" \
  || echo "${Y}[MISS]${Z}   verify_live_attestation.py"
ls -d "$ROOT"/confidential-* >/dev/null 2>&1 \
  && echo "${G}[OK]${Z}     confidential-* model repo(s)" \
  || echo "${Y}[MISS]${Z}   confidential-<model>/ (need >=1 for B4/B5)"

# ---- summary ---------------------------------------------------------------
sec "Summary"
nman=0
for k in "${!ST[@]}"; do
  [[ "${ST[$k]}" == MANUAL ]] && nman=$((nman+1))
done
for k in $(printf '%s\n' "${!ST[@]}" | sort); do
  v="${ST[$k]}"
  case "$v" in OK|FIXED) col=$G ;; *) col=$R ;; esac
  printf "%-16s ${col}%s${Z}\n" "$k" "$v"
done
echo
if [[ $nman -eq 0 ]]; then
  echo "${B}${G}All dependencies satisfied.${Z}"
else
  echo "${B}${R}$nman item(s) need manual action (see [MANUAL] above).${Z}"
fi
cat <<EOF

TWO THINGS THIS SCRIPT CANNOT DO FOR YOU (the rest is automated):
  1. authenticate gh (needed for Sigstore provenance):  gh auth login
  2. open a fresh login shell if Nix was JUST installed (so nix/go land
     on \$PATH for the current shell):
       exec \$SHELL -l
     If \`nix --version\` already works in your current shell, skip this.

Then run the verifier (which calls this script automatically if any
source repos are missing on first run):

    ./verify_build.sh

verify_build.sh uses \$VENV/bin/python directly, so you do NOT need to
\`source $VENV/bin/activate\` first.

Reproducibility: this host is $M. verify_build.sh auto-detects the live
enclave's arch from opensecret/continuum-proxy and uses the QEMU +
binfmt + Nix extra-platforms config above when a cross-arch build is
required. Go is pinned to $GO_VERSION (override: GO_VERSION=...).
EOF
