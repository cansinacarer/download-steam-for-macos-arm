# Steam ARM64 Installer without Rosetta

## TLDR

Currently you cannot install the ARM64 version of Steam on MacOS without first installing the x86 version, which requires Rosetta. This script allows you to download and install ARM64 version of Steam without needing Rosetta, from Valve's update file with one command:

```sh
curl -fsSL https://raw.githubusercontent.com/cansinacarer/download-steam-for-macos-arm/main/install.sh | bash
```

## How It Works

It pulls the universal Steam bootstrapper directly from Valve's official CDN, then verifies it TWO ways before anything touches /Applications:

  1. SHA checksum  -> download integrity (the bytes are what Valve published)
  2. Code signature -> authenticity      (the bundle is Valve's and unmodified)

Verification GATES the install: if any check fails or cannot run, the script aborts without trying to install anything.
