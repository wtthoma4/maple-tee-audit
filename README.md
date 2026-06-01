# Maple Build Verification Scripts

This repository contains two scripts that automate independent verification of Maple/Tinfoil confidential computing deployments:

* **install_deps.sh** — installs and validates all required tooling, creates a Python virtual environment, and clones the source repositories needed for verification.
* **verify_build.sh** — performs reproducible-build verification against a live deployment, validating that published artifacts, source code, enclave measurements, and build outputs match the running system.

The goal is to allow a third party to independently verify that a deployed confidential workload corresponds to publicly available source code and published build artifacts.

---

## What These Scripts Verify

The verification process checks multiple layers of the software supply chain:

* Source repositories are fetched at the revisions referenced by the deployment.
* GitHub Sigstore attestations and provenance data are verified.
* Published binaries are compared against independently rebuilt binaries.
* Enclave image measurements (PCRs) are recomputed locally.
* Rebuilt enclave artifacts are compared against the measurements reported by the live deployment.

A successful verification provides strong evidence that the deployed enclave was built from the expected source code and build inputs.

---

## Requirements

### Supported Platforms

These scripts were primarily developed and tested on:

* Debian 12
* Ubuntu 22.04+
* Fresh virtual machines with minimal customization

Other Linux distributions may work, but have not been extensively tested.

macOS support is partial and depends on the availability of required tooling.

### Privileges

Run the scripts as a normal user.

`install_deps.sh` uses `sudo` when necessary to install system packages.

---

## Quick Start

Clone this repository:

```bash
git clone <repo-url>
cd <repo>
```

Make the scripts executable:

```bash
chmod +x install_deps.sh verify_build.sh
```

Install dependencies:

```bash
./install_deps.sh
```

Authenticate GitHub CLI:

```bash
gh auth login
```

If Nix was installed during setup, start a fresh login shell:

```bash
exec $SHELL -l
```

Run verification:

```bash
./verify_build.sh
```

---

## What install_deps.sh Does

The dependency installer:

### Installs Core Tools

* curl
* jq
* git
* python3
* container runtime (Docker or Podman)

### Installs Version-Pinned Components

The following versions are intentionally constrained because different versions may produce different build outputs:

| Component       | Requirement          |
| --------------- | -------------------- |
| Go              | exact pinned version |
| GitHub CLI      | ≥ 2.67               |
| sev-snp-measure | exactly 0.0.12       |
| Nix             | flakes enabled       |

### Creates a Python Virtual Environment

A dedicated virtual environment is created under:

```text
~/.maple-verify/venv
```

unless overridden with:

```bash
VENV_DIR=/path/to/venv
```

### Clones Required Source Repositories

Repositories are cloned adjacent to the scripts and automatically refreshed on subsequent runs.

### Configures Cross-Architecture Builds

If the host architecture differs from the deployment architecture:

* QEMU user emulation is installed
* binfmt_misc handlers are registered
* Nix is configured with appropriate extra-platforms support

This allows verification from x86 hosts against ARM deployments and vice versa.

---

## Optional Environment Variables

### Select Models

```bash
MODELS=kimi-k2-6,llama-4
./install_deps.sh
```

### Override Go Version

```bash
GO_VERSION=1.25.3 ./install_deps.sh
```

### Skip Repository Cloning

```bash
NO_CLONE=1 ./install_deps.sh
```

### Custom Venv Location

```bash
VENV_DIR=/opt/maple-verify/venv ./install_deps.sh
```

---

## Cross-Architecture Verification

The scripts attempt to automatically detect whether cross-architecture emulation is required.

Examples:

| Host    | Deployment | Action       |
| ------- | ---------- | ------------ |
| x86_64  | x86_64     | native build |
| aarch64 | aarch64    | native build |
| x86_64  | aarch64    | QEMU enabled |
| aarch64 | x86_64     | QEMU enabled |

QEMU is only configured when the deployment architecture differs from the host architecture.

---

## Limitations and Known Edge Cases

These scripts were designed for clean Debian-based systems. They may not handle every environment automatically.

Examples include:

### Existing Customized Nix Installations

The scripts modify Nix configuration and may not account for heavily customized Nix setups.

### Non-Standard Linux Distributions

Package names and service layouts may differ on:

* Arch Linux
* Alpine Linux
* Gentoo
* NixOS
* Custom enterprise distributions

Manual intervention may be required.

### Locked-Down Corporate Systems

Verification may fail if:

* sudo access is unavailable
* package installation is restricted
* outbound GitHub access is blocked
* container runtimes are prohibited

### Existing Toolchain Conflicts

The installer may replace:

* Go versions
* GitHub CLI versions

Systems that depend on different versions should use an isolated VM.

### Repository Local Modifications

If cloned repositories contain local modifications, automatic updates may not succeed.

### Network Dependence

Verification requires access to:

* GitHub repositories
* GitHub release artifacts
* GitHub attestations
* Nix package sources
* deployment endpoints

Network outages or rate limits may prevent successful verification.

### Unusual Filesystems

Python virtual environments may fail on filesystems that do not support required features such as symlinks or executable files.

Examples:

* VirtualBox shared folders
* certain network shares
* some FUSE-backed filesystems

### Unsupported Architectures

The scripts primarily target:

* x86_64
* aarch64

Other architectures may require manual adaptation.

---

## Security Notes

These scripts:

* install software packages
* clone remote repositories
* download build artifacts
* configure Nix
* optionally configure QEMU/binfmt

For maximum confidence, run verification from a freshly provisioned virtual machine.

---

## Troubleshooting

### GitHub Authentication Required

```bash
gh auth login
```

is required before provenance verification can succeed.

### Nix Installed But Not Found

Start a fresh login shell:

```bash
exec $SHELL -l
```

### Nix Daemon Not Running

```bash
sudo systemctl enable --now nix-daemon
```

Verify:

```bash
nix store ping
```

### Cross-Architecture Builds Failing

Check:

```bash
nix config show | grep extra-platforms
```

and ensure the expected target architecture appears.

---

## Recommendation

For the most reproducible results:

1. Start from a fresh Debian VM.
2. Run `install_deps.sh`.
3. Authenticate GitHub CLI.
4. Run `verify_build.sh`.
5. Avoid modifying cloned repositories between verification runs.
