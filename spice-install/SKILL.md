---
name: spice-install
description: Install Spice.ai OSS CLI and runtime. Use when asked to "install Spice", "set up Spice", or "get started with Spice".
---

# Spice.ai OSS Installation

Install the Spice CLI and runtime on macOS, Linux, Windows, or WSL.

## Quick Install

**macOS, Linux, and WSL:**
```bash
curl https://install.spiceai.org | /bin/bash
```

**Homebrew:**
```bash
brew install spiceai/spiceai/spice
```

**Windows (PowerShell):**
```powershell
iex ((New-Object System.Net.WebClient).DownloadString("https://install.spiceai.org/Install.ps1"))
```

## Verify Installation

```bash
spice version
```

If command not found, add to PATH:
```bash
export PATH="$PATH:$HOME/.spice/bin"
```

## Upgrade

```bash
spice upgrade
```

## Documentation References

For detailed installation instructions, build from source, and hardware acceleration (CUDA/Metal):

- [Installation Guide](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/installation.md)
- [Getting Started](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/getting-started/index.mdx)