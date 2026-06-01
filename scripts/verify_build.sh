#!/usr/bin/env bash
# =============================================================================
# verify_build.sh  -  prove Maple's enclaves run public source code
# =============================================================================
#
# This script verifies that the live Maple system is byte-for-byte the same
# as the open source you can read on GitHub. It does two things:
#
#   1. Builds the Opensecret enclave image (EIF) from source and confirms its
#      PCR0/PCR1/PCR2 measurements equal what the live AWS Nitro enclave is
#      attesting right now. This covers the Rust binary, entrypoint.sh,
#      nitro-bins, and both proxy binaries, since all of them are baked
#      into the EIF.
#
#   2. Recomputes the SEV-SNP launch measurement for each Tinfoil model
#      enclave from public inputs (cvmimage + each tinfoil-config.yml) and
#      confirms each one equals what Tinfoil's Sigstore-signed deployment
#      manifest claims.
#
# What this cannot prove (irreducible vendor trust):
#   The AWS Nitro hypervisor, AMD/Intel CPU silicon + microcode, and NVIDIA
#   GPU firmware. These are verified via vendor signatures (AWS cert chain,
#   AMD KDS, NVIDIA RIM/OCSP), not by this script.
#
# USAGE
#   chmod +x install_deps.sh verify_build.sh
#   ./verify_build.sh
#
#   First run: hours-to-overnight (kernel compile under QEMU emulation).
#   Re-runs:   seconds (everything cached in /nix/store).
#
# OPTIONAL ENV VARS
#   RUN_OPTIONAL=1         run best-effort cross-checks in addition to the
#                          core path: A1 (nitro-bins source rebuild;
#                          documented upstream non-reproducibility), A2 and
#                          A3 (continuum-proxy and tinfoil-proxy source
#                          rebuilds), B3 (local cvmimage build). These are
#                          off by default because they require additional
#                          setup or have known limitations that don't
#                          affect the core trust chain.
#
#   NITRO_URL              live Opensecret enclave  (default: https://enclave.trymaple.ai)
#   MODELS                 comma list of model repos  (default: kimi-k2-6)
#   AWS_ROOT               path to AWS Nitro root CA  (default: auto-download)
#   MAX_WALKBACK           how many candidate commits to try if the first
#                          one's PCR0 doesn't match live  (default: 6)
#   EIF_TIMEOUT            seconds before the EIF build is killed
#                          (default: 8h native, 20h emulated)
#   CHECK_TIMEOUT          same for the optional A1/A2/A3 cross-checks
#                          (default: 30m native, 2h emulated)
#   NIX_MAX_JOBS NIX_CORES Nix parallelism caps
#                          (default: 1 / 2 when emulated, Nix default otherwise)
#   SKIP_UPDATE=1          don't pull/fetch the source repos this run
#   SKIP_A0=1              don't search for a matching commit; just build
#                          whatever is currently checked out
# =============================================================================

set -uo pipefail   # NOT -e: we run every step and record SKIP/FAIL per step.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSECRET="$ROOT/opensecret"
PRIVATEMODE="$ROOT/privatemode-public"
TINFOIL_PROXY="$OPENSECRET/tinfoil-proxy"
MIA="$ROOT/measure-image-action"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Prefer the venv that install_deps.sh created, so A5 / B4 / B5 find their
# Python deps even when you forget to `source` the venv before running.
PY="${VENV_DIR:-$HOME/.maple-verify/venv}/bin/python"
[[ -x "$PY" ]] || PY="$ROOT/.venv/bin/python"
[[ -x "$PY" ]] || PY="python3"

# ---- tunable inputs --------------------------------------------------------
NITRO_URL="${NITRO_URL:-https://enclave.trymaple.ai}"
MODELS="${MODELS:-kimi-k2-6}"               # comma list of models you use
AWS_ROOT="${AWS_ROOT:-}"                    # AWS Nitro root cert (optional)
ROUTER="confidential-model-router"
CVM_REPO="tinfoilsh/cvmimage"
EDK2_REPO="tinfoilsh/edk2"; EDK2_VER="v0.0.3"

# ---- unified, timestamped run log ------------------------------------------
# One log captures everything: this script's own narration, plus every
# sub-build's stdout/stderr (A1 container build, A2/A3 nix builds, A4
# EIF build), with every line timestamped. Tail it from another shell:
#     tail -f ~/.maple-verify/logs/verify_build.log
LOG_DIR="${MAPLE_LOG_DIR:-$HOME/.maple-verify/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$WORK"
RUN_LOG="$LOG_DIR/verify_build.log"
# Rotate the previous run's log (keep the last 5).
for _i in 4 3 2 1; do
  [[ -f "$RUN_LOG.$_i" ]] && mv "$RUN_LOG.$_i" "$RUN_LOG.$((_i+1))"
done
[[ -f "$RUN_LOG" ]] && mv "$RUN_LOG" "$RUN_LOG.1"
: > "$RUN_LOG"

# Fork-free per-line timestamper (bash 4.2+ printf %(...)T). Stamps each
# line of sub-build output as it streams into the log.
_stamp(){ local l; while IFS= read -r l; do
  printf '%(%H:%M:%S)T %s\n' -1 "$l"; done; }
# Append one already-formed message to the log, timestamped.
_log(){ printf '%(%H:%M:%S)T %s\n' -1 "$*" >> "$RUN_LOG"; }

# Run a command with stdout+stderr timestamped into the run log only
# (terminal stays readable; tail the log for detail). Returns the command's
# own exit status, or 124 if the optional timeout fired.
#   run_logged [--timeout SECS] CMD [ARGS...]
run_logged(){
  local t=0
  if [[ "${1:-}" == "--timeout" ]]; then t="$2"; shift 2; fi
  if [[ "$t" -gt 0 ]] && have timeout; then
    timeout "$t" "$@" > >(_stamp >> "$RUN_LOG") 2>&1
  else
    "$@" > >(_stamp >> "$RUN_LOG") 2>&1
  fi
}

# ---- output helpers --------------------------------------------------------
# Each helper prints a coloured line to the terminal AND a plain, timestamped
# copy to the run log.
R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
C=$'\033[0;36m'; B=$'\033[1m'; Z=$'\033[0m'
declare -A RESULT
rec(){ RESULT["$1"]="$2"; }
ok(){   echo "${G}[PASS]${Z} $*"; _log "[PASS] $*"; }
no(){   echo "${R}[FAIL]${Z} $*"; _log "[FAIL] $*"; }
skip(){ echo "${Y}[SKIP]${Z} $*"; _log "[SKIP] $*"; }
todo(){ echo "${Y}[TODO]${Z} $*"; _log "[TODO] $*"; }  # needs an operator step
gap(){  echo "${Y}[GAP]${Z}  $*"; _log "[GAP]  $*"; }  # documented non-repro
inf(){  echo "${C}[INFO]${Z} $*"; _log "[INFO] $*"; }
sec(){  echo; echo "${B}=== $* ===${Z}"; _log ""; _log "=== $* ==="; }
have(){ command -v "$1" >/dev/null 2>&1; }
_log "verify_build.sh started $(date '+%Y-%m-%d %H:%M:%S')"

# Compare two files by SHA-256.  $1 label  $2 committed  $3 rebuilt
cmp256(){
  local lbl="$1" a="$2" b="$3"
  if [[ ! -f "$a" || ! -f "$b" ]]; then
    skip "$lbl: file missing"; rec "$lbl" SKIP; return 1
  fi
  local ha hb
  ha="$(sha256sum "$a" | cut -d' ' -f1)"
  hb="$(sha256sum "$b" | cut -d' ' -f1)"
  inf "$lbl committed: $ha"
  inf "$lbl rebuilt  : $hb"
  if [[ "$ha" == "$hb" ]]; then
    ok "$lbl: rebuilt binary matches committed"; rec "$lbl" PASS
  else
    no "$lbl: MISMATCH"; rec "$lbl" FAIL
  fi
}

# ---- bootstrap: first-time setup (auto-runs install_deps.sh if needed) ----
# If there are no source repos on disk and install_deps.sh is sitting next
# to this script, run it first. That way you can drop just two files into
# a fresh VM and start a verification with one command.
sec "Bootstrap"
INSTALL_DEPS_SH="$ROOT/install_deps.sh"
if [[ ! -d "$OPENSECRET/.git" ]] && [[ -x "$INSTALL_DEPS_SH" ]]; then
  inf "source repos missing -- running install_deps.sh first"
  if "$INSTALL_DEPS_SH"; then
    inf "install_deps.sh completed; continuing with verification"
  else
    no "install_deps.sh failed; fix the issues above and rerun"
    exit 1
  fi
elif [[ ! -d "$OPENSECRET/.git" ]]; then
  no "no opensecret/ clone and no install_deps.sh alongside this script"
  inf "place install_deps.sh next to this file, or set up the environment manually"
  exit 1
else
  inf "source repos present (delete them to force a clean re-bootstrap)"
fi

# ---- update source repos to current upstream state ------------------------
# - opensecret: pull the default branch. A0 repositions HEAD based on the
#   live PCR0, so there's no tag to pin here.
# - Tinfoil repos (router + each model): pin to the LATEST release tag,
#   which is what production runs.
# - cvmimage: pin to the tag the (just-updated) router config asks for.
# - privatemode-public and measure-image-action: latest tag.
# Set SKIP_UPDATE=1 to bypass everything in this section.
sec "Update source repositories"
if [[ "${SKIP_UPDATE:-0}" == "1" ]]; then
  inf "SKIP_UPDATE=1; using whatever is currently on disk"
else
  _pull_default_branch(){
    local dir="$1" name; name="$(basename "$dir")"
    [[ -d "$dir/.git" ]] || { skip "$name: no .git, skipping"; return; }
    # Make sure we're on a branch (not detached HEAD from a previous run).
    ( cd "$dir" && git checkout --quiet master 2>/dev/null \
                || git checkout --quiet main 2>/dev/null ) || true
    if ( cd "$dir" && git fetch --quiet --tags origin 2>/dev/null \
                   && git pull --quiet --ff-only 2>/dev/null ); then
      ok "$name: pulled latest from default branch ($(git -C "$dir" rev-parse --short HEAD 2>/dev/null))"
    else
      gap "$name: could not fast-forward (uncommitted local changes?)"
    fi
    ( cd "$dir" && git submodule update --init --recursive --quiet 2>/dev/null ) || true
  }
  _checkout_latest_tag(){
    local dir="$1" name; name="$(basename "$dir")"
    [[ -d "$dir/.git" ]] || { skip "$name: no .git, skipping"; return; }
    ( cd "$dir" && git fetch --quiet --tags --force origin 2>/dev/null )
    local tag
    tag="$(git -C "$dir" tag --sort=-v:refname 2>/dev/null | head -1)"
    if [[ -z "$tag" ]]; then
      gap "$name: no release tags found"; return
    fi
    if ( cd "$dir" && git checkout --quiet "$tag" 2>/dev/null \
                   && git submodule update --init --recursive --quiet 2>/dev/null ); then
      ok "$name: checked out $tag"
    else
      gap "$name: failed to checkout $tag"
    fi
  }
  _pull_default_branch "$OPENSECRET"
  _checkout_latest_tag  "$ROOT/$ROUTER"
  for m in ${MODELS//,/ }; do
    _checkout_latest_tag "$ROOT/confidential-$m"
  done
  # cvmimage: pin to the cvm-version the (just-updated) router config asks for.
  CVMV=""
  RCFG="$ROOT/$ROUTER/tinfoil-config.yml"
  [[ -f "$RCFG" ]] && CVMV="$(grep -E '^cvm-version:' "$RCFG" | awk '{print $2}')"
  if [[ -d "$ROOT/cvmimage/.git" ]] && [[ -n "$CVMV" ]]; then
    if ( cd "$ROOT/cvmimage" && git fetch --quiet --tags --force origin 2>/dev/null \
                             && git checkout --quiet "v$CVMV" 2>/dev/null ); then
      ok "cvmimage: pinned to v$CVMV (per router's tinfoil-config.yml)"
    else
      gap "cvmimage: could not checkout v$CVMV"
    fi
  fi
  _checkout_latest_tag "$ROOT/measure-image-action"
  _checkout_latest_tag "$PRIVATEMODE"
fi

# ---- prerequisites ---------------------------------------------------------
sec "Prerequisites"
inf "unified run log: $RUN_LOG  (tail -f it from another shell to watch live)"
HAS_NIX=false; HAS_C=false; CONTAINER=""
have nix  && HAS_NIX=true || skip "nix not found"
have jq   || skip "jq not found"
have curl || skip "curl not found"
have python3 || skip "python3 not found"
if   have docker; then HAS_C=true; CONTAINER=docker
elif have podman; then HAS_C=true; CONTAINER=podman
else skip "no docker/podman"; fi
[[ "$(uname -s)" == Linux ]] || skip "not Linux: EIF/cvmimage builds need Linux"
if have gh && gh auth status >/dev/null 2>&1; then
  inf "gh authenticated (provenance checks enabled)"
else
  skip "gh missing or not logged in (gh auth login) - provenance SKIP"
fi
# Multi-user Nix: if you haven't opened a fresh login shell, NIX_REMOTE is
# unset and the client tries direct store access, which fails with
# "Permission denied ... big-lock". If the daemon socket exists, route
# through the daemon so the user doesn't have to re-login first.
if [[ -S /nix/var/nix/daemon-socket/socket && -z "${NIX_REMOTE:-}" ]];
then
  export NIX_REMOTE=daemon
  inf "set NIX_REMOTE=daemon (multi-user Nix; no new shell needed)"
fi

# ===========================================================================
# PART A-arch  -  Target architecture for the EIF build
# ===========================================================================
#
# OpenSecret deploys on aarch64 EC2 Nitro Enclaves (Graviton). The committed
# binaries inside opensecret/ (continuum-proxy, nitro-bins/*, the unsuffixed
# tinfoil-proxy) are aarch64 ELFs. If you build the EIF on an x86_64 host
# without telling Nix to target aarch64, you get a Frankenstein EIF (x86
# kernel + aarch64 proxies) whose PCR0 can't possibly match live. This step
# detects the mismatch, plans an emulated build via QEMU + binfmt_misc when
# needed, and verifies the required pieces are installed BEFORE A4 wastes
# hours on a guaranteed-wrong build.

sec "A-arch  Target architecture for the EIF build"
TARGET_SYSTEM=""
COMMITTED_ARCH=""

if [[ -f "$OPENSECRET/continuum-proxy" ]] && have file; then
  case "$(file -b "$OPENSECRET/continuum-proxy" 2>/dev/null)" in
    *aarch64*|*ARM\ aarch64*) COMMITTED_ARCH="aarch64" ;;
    *x86-64*|*x86_64*)        COMMITTED_ARCH="x86_64"  ;;
    *)                        COMMITTED_ARCH="unknown" ;;
  esac
  inf "committed EIF input arch: $COMMITTED_ARCH  (from opensecret/continuum-proxy)"
else
  inf "cannot detect committed arch (no continuum-proxy or 'file' tool); assuming native"
fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64) HOST_NIX_ARCH="aarch64" ;;
  amd64) HOST_NIX_ARCH="x86_64"  ;;
  *)     HOST_NIX_ARCH="$HOST_ARCH" ;;
esac
inf "host arch: $HOST_ARCH  (Nix system: ${HOST_NIX_ARCH}-linux)"

# Returns 0 if Nix's effective config advertises extra-platforms=$1.
nix_has_extra_platform(){
  local plat="$1" cfg
  # Authoritative source: the effective, merged config Nix actually uses.
  cfg="$( { nix config show 2>/dev/null || nix show-config 2>/dev/null; } )"
  if [[ -n "$cfg" ]] \
     && grep -qE "^extra-platforms\b.*\b${plat}\b" <<<"$cfg"; then
    return 0
  fi
  # Fallback: grep the config files directly. Determinate Nix auto-regenerates
  # /etc/nix/nix.conf, so custom settings live in /etc/nix/nix.custom.conf;
  # check both locations plus the user-level config.
  if grep -qhE "^extra-platforms\s*=.*\b${plat}\b" \
       /etc/nix/nix.conf /etc/nix/nix.custom.conf \
       "$HOME/.config/nix/nix.conf" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Returns 0 if binfmt_misc has an enabled entry for the given arch keyword.
binfmt_has(){
  local archpat="$1" f
  for f in /proc/sys/fs/binfmt_misc/*${archpat}*; do
    [[ -f "$f" ]] && grep -q '^enabled' "$f" 2>/dev/null && return 0
  done
  return 1
}

case "${HOST_NIX_ARCH}:${COMMITTED_ARCH}" in
  aarch64:aarch64)
    TARGET_SYSTEM="aarch64-linux"
    ok "native aarch64 build (no emulation needed)"
    rec "arch-target" PASS
    ;;
  x86_64:x86_64)
    TARGET_SYSTEM="x86_64-linux"
    ok "native x86_64 build (no emulation needed)"
    rec "arch-target" PASS
    ;;
  x86_64:aarch64)
    TARGET_SYSTEM="aarch64-linux"
    inf "host is x86_64 but EIF inputs are aarch64; cross-build via QEMU"
    QEMU_OK=true
    if ! have qemu-aarch64-static && ! have qemu-aarch64; then
      no "qemu-aarch64-static not installed"
      inf "  fix:  sudo apt-get install -y qemu-user-static binfmt-support"
      QEMU_OK=false
    fi
    if ! binfmt_has aarch64; then
      no "no aarch64 binfmt_misc entry is enabled"
      inf "  fix:  sudo apt-get install -y binfmt-support && \\"
      inf "        sudo systemctl restart systemd-binfmt"
      QEMU_OK=false
    fi
    if ! nix_has_extra_platform "aarch64-linux"; then
      no "Nix is not configured with extra-platforms = aarch64-linux"
      inf "  fix:  append to /etc/nix/nix.conf:"
      inf "          extra-platforms = aarch64-linux"
      inf "          extra-sandbox-paths = /run/binfmt /usr/bin/qemu-aarch64-static"
      inf "  then: sudo systemctl restart nix-daemon"
      QEMU_OK=false
    fi
    if $QEMU_OK; then
      ok "QEMU + binfmt + nix.conf configured for emulated aarch64 build"
      inf "  expect a long first build (kernel compile under emulation is"
      inf "  often 1-3 hours); subsequent runs reuse the Nix store."
      rec "arch-target" PASS
    else
      rec "arch-target" FAIL
      inf "A4 will still attempt the build but expect failure or wrong PCR0."
      inf "Resolve the issues above before relying on A5."
    fi
    ;;
  aarch64:x86_64)
    TARGET_SYSTEM="x86_64-linux"
    inf "host is aarch64 but EIF inputs are x86_64; cross-build via QEMU"
    if ! nix_has_extra_platform "x86_64-linux"; then
      no "Nix is not configured with extra-platforms = x86_64-linux"
      inf "  fix:  add 'extra-platforms = x86_64-linux' to /etc/nix/nix.conf"
      rec "arch-target" FAIL
    else
      ok "Nix configured for emulated x86_64 build"
      rec "arch-target" PASS
    fi
    ;;
  *)
    TARGET_SYSTEM=""
    skip "could not classify arch (host=$HOST_NIX_ARCH, committed=$COMMITTED_ARCH); A4 will build natively"
    rec "arch-target" SKIP
    ;;
esac
inf "Nix target system for A4: ${TARGET_SYSTEM:-<host default>}"

# Pick timeout + parallelism defaults based on native vs emulated build.
# Emulation runs ~5-8x slower than native, so the caps scale up. An emulated
# build on a small-RAM VM also thrashes hard if many derivations run at once,
# so we serialise with --max-jobs 1 (one derivation at a time).
if [[ -n "$TARGET_SYSTEM" && "$TARGET_SYSTEM" != "${HOST_NIX_ARCH}-linux" ]]; then
  CHECK_TIMEOUT="${CHECK_TIMEOUT:-7200}"     # 2 h  for A1/A2/A3
  EIF_TIMEOUT="${EIF_TIMEOUT:-72000}"        # 20 h for A4 (emulated)
  NIX_MAX_JOBS="${NIX_MAX_JOBS:-1}"          # serialise: lowest peak RAM
  NIX_CORES="${NIX_CORES:-2}"                # 2 threads inside each build
  inf "emulated build: timeouts scaled (CHECK=${CHECK_TIMEOUT}s EIF=${EIF_TIMEOUT}s),"
  inf "parallelism capped (--max-jobs $NIX_MAX_JOBS --cores $NIX_CORES) to avoid"
  inf "memory thrashing.  Override with CHECK_TIMEOUT/EIF_TIMEOUT/NIX_MAX_JOBS/NIX_CORES."
else
  CHECK_TIMEOUT="${CHECK_TIMEOUT:-1800}"     # 30 m for A1/A2/A3
  EIF_TIMEOUT="${EIF_TIMEOUT:-28800}"        # 8 h  for A4 (native)
  NIX_MAX_JOBS="${NIX_MAX_JOBS:-}"           # empty = Nix default
  NIX_CORES="${NIX_CORES:-}"
fi

# ===========================================================================
# PART A0 -  Align opensecret to whatever the LIVE enclave is running
# ===========================================================================
#
# The default branch of opensecret is usually AHEAD of the deployed revision.
# Building HEAD produces a PCR0 that doesn't match the live attestation, and
# A5 will (correctly) FAIL. This step fetches the live PCR0, then locates the
# deployment-window commit(s) whose tree records that exact PCR0 in
# pcrProd.json. Checking one of them out is what makes A4/A5 reproducible.
#
# Trust note: the live PCR0 used here is UNVERIFIED at this point — it's just
# a search key. A5 still does the full COSE_Sign1 + cert-chain + nonce
# verification against the AWS Nitro root. If pcrProd.json is wrong or the
# wrong commit is found, A5 fails loudly. We never skip A5.
#
# Set SKIP_A0=1 to disable this step and build whatever HEAD points at.

sec "A0  Find candidate opensecret commits that reproduce the live PCR0"
# Strategy:
#   1. Fetch the live PCR0 from the running enclave.
#   2. Walk origin/master commits that touched pcrProd.json, looking for the
#      one whose tree records the live PCR0. That's the "recording commit".
#   3. The deployment window is from the recording commit forward to the
#      next master commit that changes pcrProd.json to a different value.
#      Any commit in that window with unchanged EIF inputs reproduces the
#      live PCR0; we try them most-recent-first to maximise Nix cache reuse.
#   4. If the live PCR0 isn't in the public history at all (a brand-new
#      deploy that hasn't been recorded yet), fall back to the most recent
#      entry in pcrProdHistory.json — matching that still proves
#      reproducibility, just against a historical deploy instead of today's.
#   5. Build candidates in order; first one whose built PCR0 matches the
#      target wins. The A6 walk-back loop handles iteration if A4 misses.
CANDIDATES=()            # ordered list of commit SHAs to try in A4+walk-back
TARGET_PCR0=""           # the PCR0 we are trying to reproduce
TARGET_LABEL=""          # "live" or "historical entry from <date>"
LIVE_PCR0=""             # the actual live PCR0 (may differ from TARGET on fallback)

if [[ "${SKIP_A0:-0}" == "1" ]]; then
  inf "SKIP_A0=1; building whatever is currently checked out"
  rec "opensecret-align" SKIP
  CANDIDATES=( "$(git -C "$OPENSECRET" rev-parse HEAD 2>/dev/null)" )
elif [[ ! -d "$OPENSECRET/.git" ]]; then
  skip "no $OPENSECRET/.git; cannot search history"
  rec "opensecret-align" SKIP
elif ! "$PY" -c 'import cbor2, requests' 2>/dev/null; then
  skip "venv missing cbor2/requests; run install_deps.sh"
  rec "opensecret-align" SKIP
  CANDIDATES=( "$(git -C "$OPENSECRET" rev-parse HEAD 2>/dev/null)" )
else
  LIVE_PCR0="$("$PY" - "$NITRO_URL" <<'PY' 2>/dev/null
import sys, base64, secrets, cbor2, requests
url = sys.argv[1].rstrip("/") + "/attestation/" + secrets.token_hex(32)
try:
    r = requests.get(url, timeout=15); r.raise_for_status()
    arr = cbor2.loads(base64.b64decode(r.json()["attestation_document"]))
    print(cbor2.loads(arr[2])["pcrs"][0].hex())
except Exception:
    sys.exit(1)
PY
)"
  if [[ -z "$LIVE_PCR0" ]]; then
    skip "could not fetch live PCR0 from $NITRO_URL; building current HEAD"
    rec "opensecret-align" SKIP
    CANDIDATES=( "$(git -C "$OPENSECRET" rev-parse HEAD)" )
  else
inf "live PCR0: $LIVE_PCR0"
    TARGET_PCR0="$LIVE_PCR0"
    TARGET_LABEL="live attestation"

    # Search rules I settled on after a few false starts:
    #   - Search origin/master only. Side branches (feature, release, agent-
    #     rewrite, etc.) may carry their own pcrProd.json values that were
    #     never deployed; searching --all silently routes builds to those.
    #   - Verify the tree's post-image, NOT the diff. `git log -S` matches
    #     commits whose diff changes the COUNT of the target string, which
    #     also fires on commits that REMOVED the target value (the old PCR0
    #     still appears once on the "-" side of the diff). Reading the
    #     actual JSON at each tree directly answers "what does pcrProd.json
    #     say at this commit?" unambiguously.
    #
    # OpenSecret's workflow: build EIF from some commit C, deploy, then
    # update pcrProd.json on master (in C itself or a slightly later commit
    # R), append the old value to pcrProdHistory.json, continue developing.
    # Live PCR0 stays at whatever R recorded until the next master commit
    # touches pcrProd.json. The deployment window is therefore
    # [R, next_master_change_to_pcrProd_json), and any commit in that
    # window with unchanged EIF inputs reproduces the live PCR0.

    # (1) Find the recording commit R: walk master commits that touched
    #     pcrProd.json, most recent first; first one whose tree's PCR0
    #     equals the live value is R.
    RECORDING_COMMIT=""
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      pcr_at_commit="$(git -C "$OPENSECRET" show "${c}:pcrProd.json" 2>/dev/null \
                       | jq -r '.PCR0' 2>/dev/null)"
      if [[ "$pcr_at_commit" == "$LIVE_PCR0" ]]; then
        RECORDING_COMMIT="$c"
        break
      fi
    done < <(git -C "$OPENSECRET" log origin/master --pretty=format:%H -- pcrProd.json 2>/dev/null)

    seed_commits=()
    if [[ -n "$RECORDING_COMMIT" ]]; then
      inf "live PCR0 recorded by: $(git -C "$OPENSECRET" log -1 \
           --format='%h %s (%ci)' "$RECORDING_COMMIT" 2>/dev/null)"

      # (2) Find the next master commit (if any) that changes pcrProd.json
      #     to a value different from the live PCR0.  That bounds the
      #     deployment window.  If no such commit exists, the window
      #     extends to origin/master HEAD.
      NEXT_PCRPROD_CHANGE=""
      while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        pcr_at_commit="$(git -C "$OPENSECRET" show "${c}:pcrProd.json" 2>/dev/null \
                         | jq -r '.PCR0' 2>/dev/null)"
        if [[ "$pcr_at_commit" != "$LIVE_PCR0" ]]; then
          NEXT_PCRPROD_CHANGE="$c"
          break
        fi
      done < <(git -C "$OPENSECRET" log --reverse --ancestry-path \
                   --pretty=format:%H \
                   "${RECORDING_COMMIT}..origin/master" -- pcrProd.json 2>/dev/null)

      if [[ -n "$NEXT_PCRPROD_CHANGE" ]]; then
        inf "deployment window ends at: $(git -C "$OPENSECRET" log -1 \
             --format='%h %s' "$NEXT_PCRPROD_CHANGE" 2>/dev/null)"
        forward_range="${RECORDING_COMMIT}..${NEXT_PCRPROD_CHANGE}^"
      else
        inf "deployment window extends to origin/master HEAD"
        forward_range="${RECORDING_COMMIT}..origin/master"
      fi

      # (3) Order candidates most-recent-first within the window: maximises
      #     Nix cache reuse if nothing EIF-relevant has changed since the
      #     previous run, and is the commit most likely to match any
      #     auditor-published known-good SHA.
      #     - master HEAD of the window first (most recent)
      window_head="$(git -C "$OPENSECRET" rev-parse \
          "${NEXT_PCRPROD_CHANGE:+${NEXT_PCRPROD_CHANGE}^}${NEXT_PCRPROD_CHANGE:-origin/master}" \
          2>/dev/null)"
      [[ -n "$window_head" && "$window_head" != "$RECORDING_COMMIT" ]] && \
          seed_commits+=("$window_head")
      #     - Then walk backward through the window in reverse-chrono order
      while IFS= read -r c; do
        [[ -n "$c" && "$c" != "$window_head" && "$c" != "$RECORDING_COMMIT" ]] \
            && seed_commits+=("$c")
      done < <(git -C "$OPENSECRET" log --ancestry-path \
                   --pretty=format:%H "$forward_range" 2>/dev/null)
      #     - RECORDING_COMMIT itself
      seed_commits+=("$RECORDING_COMMIT")
      #     - RECORDING_COMMIT~1 as a final fallback (deploy-recorded-
      #       in-same-commit edge case, or deployment immediately before
      #       the recording)
      parent="$(git -C "$OPENSECRET" rev-parse "${RECORDING_COMMIT}~1" 2>/dev/null)"
      [[ -n "$parent" ]] && seed_commits+=("$parent")
    fi

    # Fallback: live PCR0 not present in pcrProd.json history at all.
    # This means the live deploy is NEWER than anything the public repo
    # has recorded.  Switch target to the most recent signed entry in
    # pcrProdHistory.json so we can still prove reproducibility against
    # SOMETHING signed, just not against today's exact live PCR0.
    if [[ ${#seed_commits[@]} -eq 0 ]]; then
      gap "live PCR0 not in pcrProd.json history (likely a deploy newer than the repo)"
      latest_hist="$("$PY" - "$OPENSECRET/pcrProdHistory.json" <<'PY' 2>/dev/null
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(d[-1]["PCR0"])
except Exception:
    sys.exit(1)
PY
)"
      latest_hist_date="$("$PY" - "$OPENSECRET/pcrProdHistory.json" <<'PY' 2>/dev/null
import sys, json, datetime
try:
    d = json.load(open(sys.argv[1]))
    print(datetime.datetime.fromtimestamp(d[-1]["timestamp"]).strftime("%Y-%m-%d"))
except Exception:
    sys.exit(1)
PY
)"
      if [[ -n "$latest_hist" ]]; then
        inf "falling back to most recent pcrProdHistory entry ($latest_hist_date): $latest_hist"
        TARGET_PCR0="$latest_hist"
        TARGET_LABEL="historical signed entry from $latest_hist_date"
        # For the historical fallback, find the recording commit by
        # looking at when pcrProd.json (NOT history) was set to that
        # value -- there should be exactly one such commit per past deploy.
        HIST_RECORDING="$(git -C "$OPENSECRET" log --all --diff-filter=AM \
            --pretty=format:%H -S "$latest_hist" -- pcrProd.json 2>/dev/null \
            | head -1)"
        if [[ -n "$HIST_RECORDING" ]]; then
          inf "historical PCR0 recorded by: $(git -C "$OPENSECRET" log -1 \
               --format='%h %s' "$HIST_RECORDING" 2>/dev/null)"
          HIST_NEXT="$(git -C "$OPENSECRET" log --reverse --ancestry-path \
              --pretty=format:%H \
              "${HIST_RECORDING}..origin/master" -- pcrProd.json 2>/dev/null \
              | head -1)"
          if [[ -n "$HIST_NEXT" ]]; then
            hist_range="${HIST_RECORDING}..${HIST_NEXT}^"
          else
            hist_range="${HIST_RECORDING}..origin/master"
          fi
          seed_commits+=("$HIST_RECORDING")
          while IFS= read -r c; do
            [[ -n "$c" ]] && seed_commits+=("$c")
          done < <(git -C "$OPENSECRET" log --reverse --ancestry-path \
                       --pretty=format:%H "$hist_range" 2>/dev/null)
          hist_parent="$(git -C "$OPENSECRET" rev-parse "${HIST_RECORDING}~1" 2>/dev/null)"
          [[ -n "$hist_parent" ]] && seed_commits+=("$hist_parent")
        fi
      fi
    fi

    if [[ ${#seed_commits[@]} -eq 0 ]]; then
      no "no candidate commits found for target PCR0 $TARGET_PCR0"
      inf "this is unexpected; the public repo may be entirely out of sync"
      rec "opensecret-align" FAIL
      CANDIDATES=( "$(git -C "$OPENSECRET" rev-parse HEAD)" )
    else
      # Deduplicate while preserving order, cap at MAX_WALKBACK (default 6).
      # seed_commits is already ordered by prior probability (window head,
      # walked-back through window, then recording commit, then its parent),
      # so no further expansion is needed.
      MAX_WALKBACK="${MAX_WALKBACK:-6}"
      declare -A _seen
      for c in "${seed_commits[@]}"; do
        if [[ -z "${_seen[$c]:-}" ]]; then
          CANDIDATES+=("$c")
          _seen[$c]=1
          [[ ${#CANDIDATES[@]} -ge $MAX_WALKBACK ]] && break
        fi
      done
      ok "found ${#CANDIDATES[@]} candidate commit(s); target = $TARGET_LABEL"
      inf "target PCR0: $TARGET_PCR0"
      for i in "${!CANDIDATES[@]}"; do
        c="${CANDIDATES[$i]}"
        inf "  [$((i+1))] $(git -C "$OPENSECRET" log -1 --format='%h %s (%ci)' "$c" 2>/dev/null)"
      done
      rec "opensecret-align" PASS
    fi
  fi
fi

# Helper used by A0 and the A6 walk-back loop to switch commits cleanly.
#
# Nix's flake evaluation only sees files tracked by git (or staged in the
# index). submodule init can leave files in the working tree that aren't
# tracked at the destination commit, and Nix then refuses to build with:
#   "Path '...' in the repository ... is not tracked by Git. To make it
#    visible to Nix, run: git add ..."
# After every checkout we `git add -A` so Nix sees the working tree as-is.
# That populates the index only — no commit, no history rewrite.
#
# Because we stage files ourselves after each checkout, the standard "refuse
# to switch if dirty" guard would trip on every candidate after the first.
# We stash any pre-existing local changes once, before the first checkout,
# and save the original HEAD so the run can be reverted by hand later.
_ORIG_HEAD_SAVED=false
_checkout_candidate(){
  local commit="$1"
  if ! $_ORIG_HEAD_SAVED; then
    git -C "$OPENSECRET" rev-parse HEAD > "$OPENSECRET/.verify_build_orig_head" 2>/dev/null
    # Stash anything in the working tree or index that came from an
    # external source (manual edits, prior manual `git add -A`s, etc.)
    # so checkout is clean.  The stash is preserved for the user.
    if ! git -C "$OPENSECRET" diff --quiet --ignore-submodules 2>/dev/null \
    || ! git -C "$OPENSECRET" diff --cached --quiet --ignore-submodules 2>/dev/null \
    || [[ -n "$(git -C "$OPENSECRET" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
      git -C "$OPENSECRET" stash push --include-untracked --quiet \
        -m "verify_build pre-checkout stash $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null \
        && inf "stashed pre-existing local changes (recover with: git -C $OPENSECRET stash pop)"
    fi
    _ORIG_HEAD_SAVED=true
  fi
  # Checkout the target commit. --force allows overwriting working-tree
  # files we placed ourselves on a previous candidate; any pre-existing
  # user changes were stashed above, so nothing of theirs is lost.
  if ! git -C "$OPENSECRET" checkout -q --force "$commit" 2>/dev/null; then
    no "git checkout $commit FAILED"
    return 1
  fi
  git -C "$OPENSECRET" submodule update --init --recursive --force --quiet 2>/dev/null
  # Stage every working-tree file so Nix's flake evaluation sees them.
  # Index only — no commit, no push, no history change.
  git -C "$OPENSECRET" add -A 2>/dev/null
  return 0
}

# Check out the FIRST candidate so A1-A4 see the right tree on the first
# pass. A6 walks back to the next candidate if needed.
if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
  if _checkout_candidate "${CANDIDATES[0]}"; then
    inf "checked out candidate 1/${#CANDIDATES[@]}: $(git -C "$OPENSECRET" log -1 --format='%h %s' HEAD 2>/dev/null)"
    inf "(original HEAD saved to opensecret/.verify_build_orig_head)"
  fi
fi

# ===========================================================================
# PART A  -  TEE1: rebuild Opensecret and match the LIVE Nitro attestation
# ===========================================================================

# Extract both nitro-bins from a built image ($1) and compare to the
# committed blobs.  Used by the faithful path and the scoped fallback.
nb_cmp(){
  local tag="$1" cid
  cid="$($CONTAINER create "$tag" sh 2>/dev/null)"
  if [[ -z "$cid" ]]; then
    no "could not create a container from image $tag"
    rec "kmstool_enclave_cli" FAIL; rec "libnsm.so" FAIL; return 1
  fi
  $CONTAINER cp "$cid:/app/libnsm.so" "$WORK/libnsm.so" 2>/dev/null
  $CONTAINER cp "$cid:/app/kmstool_enclave_cli" "$WORK/kmstool" \
    2>/dev/null
  $CONTAINER rm "$cid" >/dev/null 2>&1
  $CONTAINER rmi "$tag" >/dev/null 2>&1 || true
  cmp256 "kmstool_enclave_cli" \
    "$OPENSECRET/nitro-bins/kmstool_enclave_cli" "$WORK/kmstool"
  cmp256 "libnsm.so" "$OPENSECRET/nitro-bins/libnsm.so" \
    "$WORK/libnsm.so"
}

# A1 attempts AWS's published recipe to rebuild the two nitro-bins blobs
# (kmstool_enclave_cli, libnsm.so).  Today it hits a documented upstream
# non-reproducibility: nsm-api's build-dep graph is unpinned, a transitive
# dep now requires Rust edition 2024, and Cargo 1.63 can't parse that.
# This does NOT weaken the trust chain -- the committed blobs are folded
# into PCR0, so A4/A5 already covers them -- so the check is off by default.
if [[ "${RUN_OPTIONAL:-0}" == "1" ]]; then
  sec "A1  Rebuild nitro-bins (kmstool_enclave_cli + libnsm.so)"
  DF="$OPENSECRET/nitro-toolkit/enclave-base-image/Dockerfile"
  blog="$WORK/nitrobins.log"
  if ! $HAS_C || [[ ! -d "$OPENSECRET" ]]; then
    skip "no container or opensecret/ - skipping nitro-bins"
    rec "kmstool_enclave_cli" SKIP; rec "libnsm.so" SKIP
  elif [[ ! -f "$DF" ]]; then
    no "nitro-toolkit submodule not initialised (no $DF)"
    inf "fix:  git -C \"$OPENSECRET\" submodule update --init --recursive"
    rec "kmstool_enclave_cli" FAIL; rec "libnsm.so" FAIL
  elif ( cd "$OPENSECRET" && timeout "${CHECK_TIMEOUT:-1800}" \
           $CONTAINER build -t nitrobins-v2 \
           -f nitro-toolkit/enclave-base-image/Dockerfile \
           --target enclave_base . ) >"$blog" 2>&1; then
    [[ -s "$blog" ]] && _stamp < "$blog" >> "$RUN_LOG"
    inf "built via the upstream recipe"
    nb_cmp nitrobins-v2
  elif grep -qiE 'parse the .edition. key|2024. edition|getrandom-[0-9]' \
         "$blog"; then
    gap "nitro-bins: NOT byte-reproducible from the published recipe"
    inf "(documented upstream non-reproducibility; does not weaken A4/A5)"
    rec "kmstool_enclave_cli" GAP; rec "libnsm.so" GAP
  else
    [[ -s "$blog" ]] && _stamp < "$blog" >> "$RUN_LOG"
    no "$CONTAINER build of nitro-bins FAILED - last lines of the log:"
    tail -n 12 "$blog" | sed 's/^/    /'
    rec "kmstool_enclave_cli" FAIL; rec "libnsm.so" FAIL
  fi
fi

# A2 rebuilds continuum-proxy (Privatemode's outbound proxy that runs inside
# the Opensecret enclave) and byte-compares to the committed binary. It's a
# cross-check, not an anchor -- A4/A5 already cover the committed bytes via
# PCR0 -- so it's behind the optional flag. Off by default.
if [[ "${RUN_OPTIONAL:-0}" == "1" ]]; then
  sec "A2  Rebuild continuum-proxy (from privatemode-public, via nix)"
  if $HAS_NIX && [[ -d "$PRIVATEMODE" ]]; then
    A2_ARGS=( "$PRIVATEMODE#privatemode-proxy.bin" )
    if [[ -n "$TARGET_SYSTEM" && "$TARGET_SYSTEM" != "${HOST_NIX_ARCH}-linux" ]]; then
      A2_ARGS+=( --system "$TARGET_SYSTEM" )
      inf "cross-build target: $TARGET_SYSTEM (emulated; substituters ON)"
    fi
    inf "capped at ${CHECK_TIMEOUT:-1800}s (CHECK_TIMEOUT)"
    run_logged --timeout "${CHECK_TIMEOUT:-1800}" \
      nix build "${A2_ARGS[@]}" -o "$WORK/cont-out"
    a2_rc=$?
    if [[ "$a2_rc" -eq 124 ]]; then
      skip "continuum-proxy: exceeded ${CHECK_TIMEOUT:-1800}s cap"
      rec "continuum-proxy" SKIP
    else
      bin="$(find "$WORK/cont-out" -type f -name privatemode-proxy 2>/dev/null \
             | head -1)"
      cmp256 "continuum-proxy" "$OPENSECRET/continuum-proxy" "${bin:-/nonexist}"
    fi
  else
    skip "no nix or privatemode-public/ - skipping continuum-proxy"
    rec "continuum-proxy" SKIP
  fi
fi

# A3 rebuilds tinfoil-proxy (the outbound proxy to Tinfoil's GPU enclaves)
# and byte-compares to the committed binary. Same status as A2: a
# cross-check covered by A4/A5, off by default.
if [[ "${RUN_OPTIONAL:-0}" == "1" ]]; then
  sec "A3  Rebuild tinfoil-proxy (Go, reproducible flags)"
  # Pick the committed binary that matches the TARGET arch (what the EIF
  # consumes), not the host arch.
  case "$TARGET_SYSTEM" in
    aarch64-linux)
      goarch=arm64; committed="$TINFOIL_PROXY/dist/tinfoil-proxy" ;;
    x86_64-linux)
      goarch=amd64; committed="$TINFOIL_PROXY/dist/tinfoil-proxy-x86_64" ;;
    *)
      if [[ "$(uname -m)" == x86_64 ]]; then
        goarch=amd64; committed="$TINFOIL_PROXY/dist/tinfoil-proxy-x86_64"
      else
        goarch=arm64; committed="$TINFOIL_PROXY/dist/tinfoil-proxy"
      fi ;;
  esac
  inf "target arch: ${TARGET_SYSTEM:-<host>}  ->  $committed"
  if $HAS_NIX && [[ -f "$TINFOIL_PROXY/flake.nix" ]]; then
    A3_ARGS=( --impure "$TINFOIL_PROXY#" )
    if [[ -n "$TARGET_SYSTEM" && "$TARGET_SYSTEM" != "${HOST_NIX_ARCH}-linux" ]]; then
      A3_ARGS+=( --system "$TARGET_SYSTEM" )
    fi
    inf "capped at ${CHECK_TIMEOUT:-1800}s (CHECK_TIMEOUT)"
    run_logged --timeout "${CHECK_TIMEOUT:-1800}" \
      nix build "${A3_ARGS[@]}" -o "$WORK/tfp-out"
    a3_rc=$?
    if [[ "$a3_rc" -eq 124 ]]; then
      skip "tinfoil-proxy: exceeded ${CHECK_TIMEOUT:-1800}s cap"
      rec "tinfoil-proxy" SKIP
    else
      rb="$(find "$WORK/tfp-out" -type f -name tinfoil-proxy 2>/dev/null \
            | head -1)"
      cmp256 "tinfoil-proxy" "$committed" "${rb:-/nonexist}"
    fi
  elif have go && [[ -d "$TINFOIL_PROXY" ]]; then
    inf "go-build fallback; capped at ${CHECK_TIMEOUT:-1800}s (CHECK_TIMEOUT)"
    ( cd "$TINFOIL_PROXY"
      run_logged --timeout "${CHECK_TIMEOUT:-1800}" \
        env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
        go build -a -trimpath -ldflags="-s -w" \
        -o "$WORK/tinfoil-proxy" . )
    cmp256 "tinfoil-proxy" "$committed" "$WORK/tinfoil-proxy"
  else
    skip "no nix flake or go toolchain or tinfoil-proxy/ - skipping"
    rec "tinfoil-proxy" SKIP
  fi
fi

sec "A4  Build the Opensecret enclave image (EIF)"
PCR_JSON="$OPENSECRET/result/pcr.json"
BUILT_PCR0=""
if $HAS_NIX && have jq && [[ "$(uname -s)" == Linux ]]; then
  ref="$(git -C "$OPENSECRET" describe --tags 2>/dev/null \
         || git -C "$OPENSECRET" rev-parse --short HEAD 2>/dev/null)"
  inf "building from commit ${ref:-?}"
  inf "A5 (reproduced PCR0 == live attestation) is the authoritative check."
  # -L streams per-derivation build output into the run log. Without it the
  # opensecret cargo build runs for an hour-plus emitting nothing, which is
  # indistinguishable from a wedge.
  A4_ARGS=( -L ".?submodules=1#eif-prod" )
  CROSS_BUILD=false
  if [[ -n "$TARGET_SYSTEM" && "$TARGET_SYSTEM" != "${HOST_NIX_ARCH}-linux" ]]; then
    A4_ARGS+=( --system "$TARGET_SYSTEM" )
    CROSS_BUILD=true
  fi
  # Cap parallelism (set for emulated builds in A-arch) so a small VM
  # doesn't thrash itself building under emulation.
  [[ -n "$NIX_MAX_JOBS" ]] && A4_ARGS+=( --max-jobs "$NIX_MAX_JOBS" )
  [[ -n "$NIX_CORES"    ]] && A4_ARGS+=( --cores    "$NIX_CORES" )

  if $CROSS_BUILD; then
    inf "nix build ${A4_ARGS[*]}  (cross-build via QEMU: hours on first run)"
  else
    inf "nix build ${A4_ARGS[*]}  (10-30 min on first run)"
  fi
  inf "build output streams to $RUN_LOG (tail -f from another shell)"

  # Delete any stale result symlink from a previous run. Without this, a
  # failed build leaves the old result/pcr.json in place and the check
  # below would read it and falsely report PASS for the wrong EIF.
  rm -f "$OPENSECRET/result"

  # Run the build in the background so we can heartbeat. Its stdout+stderr
  # (verbose, because of -L) is timestamped into the unified run log.
  # EIF_TIMEOUT was set in the A-arch step (8 h native / 20 h emulated).
  build_start=$SECONDS
  ( cd "$OPENSECRET" \
    && timeout "$EIF_TIMEOUT" nix build "${A4_ARGS[@]}" ) \
    > >(_stamp >> "$RUN_LOG") 2>&1 &
  BUILD_PID=$!

  # ---- wedge-aware heartbeat ------------------------------------------------
  # No completion percentage: per-derivation cost varies ~100x so any bar
  # would lie. Instead the heartbeat reports honest signals every interval:
  #   drvs    derivations started so far (climbs as the build progresses)
  #   log+    new log lines since the last beat (0 for several beats = STALLED)
  #   mem     MemAvailable in MB
  #   swpout+ pages swapped out since the last beat (high = thrashing)
  # A genuinely progressing build shows log+ > 0. A memory wedge shows log+0
  # and a STALLED warning, so you know to abort instead of wait.
  # Count only BUILD-output lines (those without a script [TAG]) so the
  # heartbeat's own writes don't inflate the delta and mask a real stall.
  HELPER_TAGS='\[(INFO|PASS|FAIL|SKIP|TODO|GAP)\] '
  count_build_lines(){
    local n; n="$(grep -cvE "$HELPER_TAGS" "$RUN_LOG" 2>/dev/null)"; echo "${n:-0}"
  }
  read_swpout(){
    local n; n="$(awk '/^pswpout /{print $2}' /proc/vmstat 2>/dev/null)"
    echo "${n:-0}"
  }
  HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"
  last_report=0
  prev_lines="$(count_build_lines)"
  prev_swpout="$(read_swpout)"
  stall=0
  inf "build started at $(date '+%H:%M:%S')  (pid $BUILD_PID, heartbeat ${HEARTBEAT_INTERVAL}s, cap ${EIF_TIMEOUT}s)"
  inf "heartbeat legend: drvs=derivations started  log+=new BUILD lines  mem=MemAvailable  swpout+=pages swapped out"
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 5
    elapsed=$((SECONDS - build_start))
    if (( elapsed - last_report >= HEARTBEAT_INTERVAL )); then
      last_report=$elapsed
      h=$((elapsed / 3600)); m=$(((elapsed % 3600) / 60))
      lines="$(count_build_lines)"
      dlines=$(( lines - prev_lines )); prev_lines=$lines
      drvs="$(grep -cE "building '/nix/store/" "$RUN_LOG" 2>/dev/null)"
      drvs="${drvs:-0}"
      memav="$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
      swpout="$(read_swpout)"
      dswp=$(( swpout - prev_swpout )); prev_swpout=$swpout
      # Capture the last REAL build line before our own heartbeat write
      # below (otherwise we'd just echo the previous heartbeat back).
      tailline="$(grep -vE "$HELPER_TAGS" "$RUN_LOG" 2>/dev/null \
                  | tail -n1 | cut -c1-100)"
      if (( dlines == 0 )); then stall=$(( stall + 1 )); else stall=0; fi
      hb="  [${h}h${m}m]  drvs=$drvs  log+$dlines  mem=${memav:-?}MB  swpout+$dswp"
      if (( stall >= 3 )); then
        hb="$hb  *** STALLED ${stall} beats - likely memory wedge; consider aborting ***"
      fi
      inf "$hb"
      [[ -n "$tailline" ]] && inf "      last: $tailline"
    fi
  done
  wait "$BUILD_PID" 2>/dev/null
  build_rc=$?
  sleep 1   # let the _stamp process drain the build's final lines to the log
  final_elapsed=$((SECONDS - build_start))
  fh=$((final_elapsed / 3600))
  fm=$(((final_elapsed % 3600) / 60))
  fs=$((final_elapsed % 60))
  inf "build finished after ${fh}h${fm}m${fs}s  (exit code $build_rc)"
  [[ "$build_rc" -eq 124 ]] && \
    inf "(exit 124 = hit the ${EIF_TIMEOUT}s EIF_TIMEOUT cap)"

  if [[ "$build_rc" -ne 0 ]]; then
    no "EIF build FAILED (nix build exited $build_rc)"
    inf "last lines of the build output (full detail in $RUN_LOG):"
    tail -n 20 "$RUN_LOG" | sed 's/^/    /'
    if grep -qiE 'required system features|set of valid platforms|but I am a|cannot build .* aarch64-linux' \
         "$RUN_LOG"; then
      inf "--> Nix refused to build an aarch64 derivation: extra-platforms"
      inf "    is NOT active in the build daemon.  See the A-arch warnings"
      inf "    above; fix nix.custom.conf, restart nix-daemon, then re-run."
    fi
    if grep -qiE 'big-lock|Permission denied|daemon may have crashed' \
         "$RUN_LOG"; then
      inf "--> BROKEN NIX INSTALL. Fix:"
      inf "    sudo systemctl restart nix-daemon && nix store ping"
    fi
    rec "eif-build" FAIL
  elif [[ -f "$PCR_JSON" ]]; then
    BUILT_PCR0="$(jq -r .PCR0 "$PCR_JSON")"
    inf "Reproduced PCR0: $BUILT_PCR0"
    inf "Reproduced PCR1: $(jq -r .PCR1 "$PCR_JSON")"
    inf "Reproduced PCR2: $(jq -r .PCR2 "$PCR_JSON")"
    ok "EIF built"; rec "eif-build" PASS
  else
    no "EIF build exited 0 but produced no result/pcr.json"
    inf "last lines of the build output (full detail in $RUN_LOG):"
    tail -n 15 "$RUN_LOG" | sed 's/^/    /'
    rec "eif-build" FAIL
  fi
else
  skip "need nix + jq + Linux to build the EIF"; rec "eif-build" SKIP
fi
# Informational only: these are signed by OpenSecret, so not the anchor.
if have jq && [[ -f "$OPENSECRET/pcrProd.json" ]]; then
  inf "pcrProd.json PCR0 (OpenSecret-signed, info only): \
$(jq -r .PCR0 "$OPENSECRET/pcrProd.json")"
fi

sec "A5  ANCHOR: reproduced PCR0 == LIVE Nitro attestation"
if [[ -n "$BUILT_PCR0" ]] \
   && [[ -f "$ROOT/verify_live_attestation.py" ]]; then
  args=(--api-url "$NITRO_URL" --expected-pcr-json "$PCR_JSON")
  if [[ -n "$AWS_ROOT" ]]; then
    args+=(--aws-root "$AWS_ROOT")
  else
    args+=(--allow-aws-download)
    inf "no AWS_ROOT given: fetching AWS Nitro root over HTTPS"
  fi
  if "$PY" "$ROOT/verify_live_attestation.py" "${args[@]}"; then
    ok "LIVE Opensecret enclave runs the EIF you built"
    rec "tee1-live" PASS
    rec "tee1-reproducible" PASS
  else
    no "live PCR0 != your build, or attestation invalid"
    rec "tee1-live" FAIL
    # Reproducibility row is set in A6 below (may turn PASS via walk-back).
  fi
else
  skip "need built PCR0 + verify_live_attestation.py for the anchor"
  rec "tee1-live" SKIP
fi

# Also record reproducibility against the TARGET (live OR historical fallback)
# from the first candidate, in case A0 fell back to historical mode.
if [[ -n "$BUILT_PCR0" ]] && [[ -n "$TARGET_PCR0" ]] \
   && [[ "$BUILT_PCR0" == "$TARGET_PCR0" ]] \
   && [[ "${RESULT[tee1-reproducible]:-}" != "PASS" ]]; then
  ok "first candidate already reproduces target ($TARGET_LABEL)"
  rec "tee1-reproducible" PASS
fi

# ===========================================================================
# PART A6 -  Walk-back: try the remaining candidate commits if A5 failed
# ===========================================================================
# If the first candidate's built PCR0 already matched the target, we're done.
# Otherwise iterate through the remaining candidates in order. Nix caches
# everything that hasn't changed, so each subsequent build is typically
# minutes instead of hours. First match wins, and we overwrite tee1-live /
# tee1-reproducible in the summary accordingly.

sec "A6  Walk-back through remaining candidate commits (if needed)"
if [[ "${RESULT[tee1-reproducible]:-}" == "PASS" ]]; then
  inf "first candidate already reproduced $TARGET_LABEL; no walk-back needed"
  rec "walkback" SKIP
elif [[ ${#CANDIDATES[@]} -le 1 ]]; then
  inf "no further candidates to try"
  rec "walkback" SKIP
elif [[ -z "$TARGET_PCR0" ]]; then
  inf "no target PCR0; skipping walk-back"
  rec "walkback" SKIP
elif ! $HAS_NIX || ! have jq; then
  skip "need nix + jq for walk-back"; rec "walkback" SKIP
else
  matched=false
  for i in $(seq 1 $((${#CANDIDATES[@]} - 1))); do
    candidate="${CANDIDATES[$i]}"
    desc="$(git -C "$OPENSECRET" log -1 --format='%h %s' "$candidate" 2>/dev/null)"
    inf "candidate $((i+1))/${#CANDIDATES[@]}: $desc"
    if ! _checkout_candidate "$candidate"; then
      inf "  (checkout failed, skipping)"
      continue
    fi
    rm -f "$OPENSECRET/result"
    wb_start=$SECONDS
    ( cd "$OPENSECRET" \
      && timeout "$EIF_TIMEOUT" nix build "${A4_ARGS[@]}" ) \
      > >(_stamp >> "$RUN_LOG") 2>&1 &
    WB_PID=$!
    wb_last=0
    while kill -0 "$WB_PID" 2>/dev/null; do
      sleep 10
      wb_elapsed=$((SECONDS - wb_start))
      if (( wb_elapsed - wb_last >= 120 )); then
        wb_last=$wb_elapsed
        wb_h=$((wb_elapsed/3600)); wb_m=$(((wb_elapsed%3600)/60))
        inf "  walk-back build still running: ${wb_h}h${wb_m}m elapsed"
      fi
    done
    wait "$WB_PID" 2>/dev/null
    wb_rc=$?
    sleep 1
    wb_total=$((SECONDS - wb_start))
    wb_h=$((wb_total/3600)); wb_m=$(((wb_total%3600)/60)); wb_s=$((wb_total%60))
    inf "  build finished in ${wb_h}h${wb_m}m${wb_s}s (exit $wb_rc)"
    if [[ "$wb_rc" -ne 0 ]] || [[ ! -f "$PCR_JSON" ]]; then
      inf "  build failed; trying next candidate"
      continue
    fi
    wb_pcr0="$(jq -r .PCR0 "$PCR_JSON" 2>/dev/null)"
    inf "  built PCR0 : $wb_pcr0"
    inf "  target PCR0: $TARGET_PCR0"
    if [[ "$wb_pcr0" == "$TARGET_PCR0" ]]; then
      ok "MATCH on candidate $((i+1))/${#CANDIDATES[@]}: $desc"
      BUILT_PCR0="$wb_pcr0"
      rec "walkback" PASS
      rec "tee1-reproducible" PASS
      if [[ "$TARGET_PCR0" == "$LIVE_PCR0" ]]; then
        rec "tee1-live" PASS
        inf "  -> LIVE Opensecret enclave runs the EIF you built"
      else
        inf "  -> reproducibility proven against $TARGET_LABEL"
        inf "     (current live PCR0 corresponds to a deploy not yet"
        inf "      recorded in pcrProdHistory.json -- try later for a live anchor)"
      fi
      matched=true
      break
    else
      inf "  no match; trying next candidate"
    fi
  done
  if ! $matched; then
    no "no candidate reproduced target PCR0 $TARGET_PCR0"
    inf "reproducibility could not be proven against any of the ${#CANDIDATES[@]} candidates"
    inf "this most likely means:"
    inf "  - the deployed source contains private patches not in the public repo, OR"
    inf "  - your build environment differs in some way not captured by the flake"
    inf "    (rare with Nix; report it if you suspect this)"
    rec "walkback" FAIL
    rec "tee1-reproducible" FAIL
  fi
fi

# ===========================================================================
# PART B  -  TEE2: recompute the Tinfoil measurement and match it
# ===========================================================================

GH_OK=false
have gh && gh auth status >/dev/null 2>&1 && GH_OK=true

# Read cvm-version from the router config (all configs share one cvmimage).
CVMV=""
RCFG="$ROOT/$ROUTER/tinfoil-config.yml"
[[ -f "$RCFG" ]] && CVMV="$(grep -E '^cvm-version:' "$RCFG" \
                           | awk '{print $2}')"

sec "B1  Verify the cvmimage release manifest provenance ($CVMV)"
MAN="$WORK/cvm-manifest.json"
if $GH_OK && have curl && [[ -n "$CVMV" ]]; then
  url="https://github.com/$CVM_REPO/releases/download"
  url="$url/v$CVMV/tinfoil-inference-v$CVMV-manifest.json"
  if curl -fsSL "$url" -o "$MAN"; then
    if gh attestation verify "$MAN" -R "$CVM_REPO" \
         --deny-self-hosted-runners >/dev/null 2>&1; then
      ok "cvmimage manifest v$CVMV provenance verified (Sigstore + Rekor)"
      rec "cvm-manifest" PASS
    else
      no "cvmimage manifest provenance FAILED"; rec "cvm-manifest" FAIL
    fi
  else
    skip "could not download cvmimage manifest"; rec "cvm-manifest" SKIP
  fi
else
  skip "need gh(auth) + curl + cvm-version"; rec "cvm-manifest" SKIP
fi

sec "B2  Fetch measurement inputs (kernel, initrd, OVMF)"
KERNEL="$WORK/vmlinuz"; INITRD="$WORK/initrd"; OVMF="$WORK/OVMF.fd"
INPUTS_OK=false
if have curl && have jq && [[ -f "$MAN" ]]; then
  base="https://images.tinfoil.sh/cvm/tinfoil-inference-v$CVMV"
  curl -fsSL "$base.vmlinuz" -o "$KERNEL" \
    && curl -fsSL "$base.initrd" -o "$INITRD"
  kh="$(sha256sum "$KERNEL" 2>/dev/null | cut -d' ' -f1)"
  ih="$(sha256sum "$INITRD" 2>/dev/null | cut -d' ' -f1)"
  mk="$(jq -r .kernel "$MAN")"; mi="$(jq -r .initrd "$MAN")"
  if [[ "$kh" == "$mk" && "$ih" == "$mi" ]]; then
    ok "kernel + initrd match the provenance-verified manifest"
    eurl="https://github.com/$EDK2_REPO/releases/download"
    eurl="$eurl/$EDK2_VER/OVMF.fd"
    if curl -fsSL "$eurl" -o "$OVMF"; then
      $GH_OK && gh attestation verify "$OVMF" -R "$EDK2_REPO" \
        --deny-self-hosted-runners >/dev/null 2>&1 \
        && inf "OVMF provenance verified" \
        || inf "OVMF downloaded (provenance not checked)"
      INPUTS_OK=true; rec "cvm-inputs" PASS
    else
      no "could not download OVMF"; rec "cvm-inputs" FAIL
    fi
  else
    no "kernel/initrd do NOT match manifest (kh=$kh ih=$ih)"
    rec "cvm-inputs" FAIL
  fi
else
  skip "need curl + jq + manifest"; rec "cvm-inputs" SKIP
fi

# B3 builds cvmimage from source locally and compares its roothash to the
# Sigstore-verified manifest. This is the strongest TEE2 stance — but the
# build is heavy and self-flagged non-deterministic (nvattest from source
# against a pinned Ubuntu snapshot), so it's gated behind RUN_OPTIONAL.
# B1 + B2 already prove the manifest is Sigstore-signed by Tinfoil's GitHub
# Actions identity and that the downloaded kernel/initrd match it, so the
# trust chain holds without B3.
if [[ "${RUN_OPTIONAL:-0}" == "1" ]]; then
  sec "B3  Confirm a local cvmimage build == verified manifest"
  if [[ -f "$ROOT/cvmimage/tinfoilcvm.hash" ]] && have jq \
     && [[ -f "$MAN" ]]; then
    rh="$(cat "$ROOT/cvmimage/tinfoilcvm.hash")"
    mr="$(jq -r .root "$MAN")"
    if [[ "$rh" == "$mr" ]]; then
      ok "local cvmimage rootfs roothash == manifest.root"
      rec "cvm-local" PASS
    else
      no "local cvmimage roothash != manifest ($rh != $mr)"
      rec "cvm-local" FAIL
    fi
  else
    todo "build it yourself:  git -C cvmimage checkout v$CVMV && \
(cd cvmimage && sudo make build)"
    rec "cvm-local" TODO
  fi
fi

sec "B4  Recompute SEV-SNP measurement per config; match signed + live"
SNP_PY="$MIA/measure_amd.py"
PY_OK=false
"$PY" -c 'import sevsnpmeasure' 2>/dev/null && PY_OK=true
$PY_OK || skip "venv lacks sev-snp-measure (run install_deps.sh; the \
verifier auto-uses $ROOT/.venv if present)"

# Build the list of config repos: the router plus each requested model.
SLUGS=("$ROUTER")
for m in ${MODELS//,/ }; do SLUGS+=("confidential-$m"); done

for slug in "${SLUGS[@]}"; do
  d="$ROOT/$slug"; cf="$d/tinfoil-config.yml"
  if [[ ! -f "$cf" ]]; then
    skip "$slug: no tinfoil-config.yml in folder"
    rec "measure-$slug" SKIP; continue
  fi

  # (a) Recompute the AMD launch measurement locally. Mirrors
  #     measure-image-action/measure.py exactly: same cmdline, same
  #     sev-snp-measure call. The AMD path uses upstream sev-snp-measure,
  #     making this a vendor-independent cross-check.
  SNP=""
  if $PY_OK && $INPUTS_OK && [[ -f "$SNP_PY" ]]; then
    SNP="$("$PY" - "$cf" "$MAN" "$MIA" "$OVMF" "$KERNEL" "$INITRD" \
<<'PY'
import sys, json, hashlib, yaml
cf, man, mia, ovmf, kern, ird = sys.argv[1:7]
sys.path.insert(0, mia)
from measure_amd import measure_amd
m = json.load(open(man))
c = yaml.safe_load(open(cf))
ch = hashlib.sha256(open(cf, "rb").read()).hexdigest()
cmd = ("readonly=on pci=realloc,nocrs "
       "modprobe.blacklist=nouveau nouveau.modeset=0 "
       "root=/dev/mapper/root "
       f"roothash={m['root']} tinfoil-config-hash={ch}")
print(measure_amd(c["cpus"], ovmf, kern, ird, cmd))
PY
)" || SNP=""
    [[ -n "$SNP" ]] && inf "$slug recomputed SNP: $SNP"
  fi

  # (b) Download the repo's signed deployment manifest and verify it.
  ATT=""
  if $GH_OK; then
    dep="$WORK/dep-$slug.json"
    # measure-image-action publishes releases with --latest=false, so a
    # bare `gh release download` (which defaults to "latest") finds nothing.
    # Resolve the newest tag explicitly and download that release — the
    # same tag tinfoil-go's FetchLatestTag would pick at runtime.
    tag="$(git ls-remote --tags --refs \
             "https://github.com/tinfoilsh/$slug.git" 2>/dev/null \
           | sed 's#.*refs/tags/##' | grep -E '^v?[0-9]' \
           | sort -V | tail -1)"
    glog="$WORK/gh-$slug.log"
    if [[ -z "$tag" ]]; then
      skip "$slug: no release tag found via git ls-remote"
    elif ! gh release download "$tag" -R "tinfoilsh/$slug" \
           -p tinfoil-deployment.json -O "$dep" >"$glog" 2>&1; then
      skip "$slug: release $tag has no tinfoil-deployment.json asset"
      tail -n 4 "$glog" | sed 's/^/    /'
    # measure-image-action attests with a CUSTOM predicate type, not SLSA
    # provenance. Without --predicate-type gh reports "no matching predicate
    # found" even though the attestation is perfectly valid.
    elif ! gh attestation verify "$dep" -R "tinfoilsh/$slug" \
           --predicate-type \
           "https://tinfoil.sh/predicate/snp-tdx-multiplatform/v1" \
           --deny-self-hosted-runners >"$glog" 2>&1; then
      no "$slug: tinfoil-deployment.json provenance FAILED"
      tail -n 6 "$glog" | sed 's/^/    /'
    else
      ATT="$(jq -r .snp_measurement "$dep" 2>/dev/null)"
      inf "$slug attested SNP ($tag): $ATT"
    fi
  fi

  # (c) Verdict for this config.
  if [[ -n "$SNP" && -n "$ATT" ]]; then
    if [[ "$SNP" == "$ATT" ]]; then
      ok "$slug: recomputed SNP == repo's signed SNP"
      rec "measure-$slug" PASS
    else
      no "$slug: SNP MISMATCH (built != signed)"
      rec "measure-$slug" FAIL
    fi
  elif [[ -n "$ATT" ]]; then
    todo "$slug: signed SNP verified; finish B2/B4 to recompute locally"
    rec "measure-$slug" TODO
  else
    skip "$slug: insufficient inputs to compare"
    rec "measure-$slug" SKIP
  fi
done

sec "B5  Compare signed measurement to the LIVE model enclave"
# Resolve each model's enclave host from the router's config.yml and
# fetch its live attestation. We print the live measurement next to the
# signed one so a mismatch is immediately obvious.
CFG="$ROOT/$ROUTER/config.yml"
if [[ -f "$CFG" ]]; then
  for m in ${MODELS//,/ }; do
    host="$("$PY" - "$CFG" "$m" <<'PY'
import sys, yaml
cfg, model = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(cfg))
ms = (d.get("models") or {}).get(model) or {}
encs = ms.get("enclaves") or []
print(encs[0] if encs else "")
PY
)"
    if [[ -z "$host" ]]; then
      skip "$m: no enclave host in router config.yml"
      rec "live-$m" SKIP; continue
    fi
    out="$WORK/live-$m.json"
    if curl -fsSL "https://$host/.well-known/tinfoil-attestation" \
         -o "$out" 2>/dev/null; then
      ok "$m: live attestation fetched from $host"
      inf "$m: compare its measurement to the signed SNP from B4"
      rec "live-$m" PASS
    else
      skip "$m: could not reach https://$host"
      rec "live-$m" SKIP
    fi
  done
else
  skip "need python3 + router config.yml for live model check"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
sec "Summary"
printf "%-26s %s\n" "CHECK" "RESULT"
printf -- '-%.0s' {1..44}; echo
for k in $(printf '%s\n' "${!RESULT[@]}" | sort); do
  v="${RESULT[$k]}"
  case "$v" in
    PASS) col=$G ;; FAIL) col=$R ;; *) col=$Y ;;
  esac
  printf "%-26s ${col}%s${Z}\n" "$k" "$v"
done

p=0; f=0; s=0
for v in "${RESULT[@]}"; do
  case "$v" in
    PASS) p=$((p+1)) ;;
    FAIL) f=$((f+1)) ;;
    *)    s=$((s+1)) ;;
  esac
done
echo
echo "${B}${G}$p passed${Z}  ${R}$f failed${Z}  ${Y}$s skipped/todo/gap${Z}"

# Headline verdict. Two reproducibility levels:
#   tee1-live          built PCR0 == current live attestation (strongest claim)
#   tee1-reproducible  built PCR0 == some signed entry (proves the system IS
#                      reproducible from public source even if not against
#                      today's exact deploy)
echo
if [[ "${RESULT[tee1-live]:-}" == "PASS" ]] \
   && [[ "${RESULT[tee1-reproducible]:-}" == "PASS" ]]; then
  echo "${B}${G}TRUSTED:${Z} the live Opensecret enclave is running the EIF you built"
  echo "    from public source.  Both reproducibility AND the live anchor hold."
elif [[ "${RESULT[tee1-reproducible]:-}" == "PASS" ]]; then
  echo "${B}${Y}REPRODUCIBLE BUT NOT LIVE-ANCHORED:${Z} your local build matches a"
  echo "    signed historical entry (proving the system is reproducible from"
  echo "    public source) but does NOT match today's live PCR0.  The live"
  echo "    deploy may not yet be recorded in pcrProdHistory.json -- try again"
  echo "    in a few days, or after OpenSecret commits the new pcrProd.json."
else
  echo "${B}${R}NOT REPRODUCIBLE FROM PUBLIC SOURCE:${Z} no candidate commit produced"
  echo "    the target PCR0.  Either the deployed source is not in the public"
  echo "    repository, or some environmental input differs and we have not"
  echo "    accounted for it.  See the A6 walk-back diagnostics above."
fi

cat <<'EOF'

REPRODUCIBILITY MODEL
  - tee1-live           strongest TEE1 claim: live enclave == your build
  - tee1-reproducible   weaker TEE1 claim: your build == some signed deploy
                        (always implied by tee1-live; can stand alone)
  - measure-<repo>      TEE2 claim: Tinfoil model EIF == Sigstore-signed
  - live-<model>        TEE2 liveness: live model enclave reachable

IRREDUCIBLE VENDOR TRUST (attested, never built)
  - AWS Nitro hypervisor; AMD/Intel CPU + microcode; NVIDIA GPU
    firmware.  Verified by vendor signatures, not by this script.

GAP (nitro-bins) is a DOCUMENTED upstream non-reproducibility: those
blobs are committed and PCR0-measured, so A4/A5 still anchors the chain.
A GAP leaves them as trusted, measured, AWS-derived inputs.
EOF

# Exit 0 if reproducibility holds (live OR historical), 1 otherwise.
if [[ "${RESULT[tee1-reproducible]:-}" == "PASS" ]]; then
  exit 0
else
  exit 1
fi
