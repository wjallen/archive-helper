# Tape Archive System

A shell script suite for archiving large directory structures to a tape system via SSH. Designed for millions of files and folders with automatic sizing into tar archives between 100GB and 1TB.

## Scripts

| Script | Purpose |
|--------|---------|
| `archive.sh` | Create archives from source directory |
| `archive-verify.sh` | Verify archive integrity |
| `archive-restore.sh` | Restore data from archives |
| `archive-progress.sh` | Check archive status and progress |

## Quick Start

```bash
# Archive data
./archive.sh \
  --source /data \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --min-size 100GB \
  --max-size 1TB

# Check progress
./archive-progress.sh \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive

# Verify archives
./archive-verify.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --checksum

# Restore all data
./archive-restore.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --destination /restore/path \
  --all
```

## archive.sh

Creates tar archives from a source directory, automatically grouping subdirectories to meet size constraints.

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--source PATH` | Yes | Source directory to archive (absolute path) |
| `--tape-host HOST` | Yes | SSH host for tape system (user@host format) |
| `--tape-path PATH` | Yes | Remote path on tape system for tar files |
| `--min-size SIZE` | Yes | Minimum tar file size (e.g., 100GB, 500G, 1TB) |
| `--max-size SIZE` | Yes | Maximum tar file size (e.g., 1TB, 1024G) |
| `--threads N` | No | Number of parallel tar operations (default: 1) |
| `--dry-run` | No | Show what would be archived without creating tar files |
| `--help` | No | Show usage information |

### Size Format

Size can be specified with units:
- `B` or no unit: bytes
- `KB` or `K`: kilobytes
- `MB` or `M`: megabytes
- `GB` or `G`: gigabytes
- `TB` or `T`: terabytes

### How It Works

1. **Scan**: Recursively walks the source directory and calculates the size of each top-level subdirectory
2. **Group**: Automatically groups subdirectories to create tar files within the min/max size range
3. **Archive**: Creates tar files over SSH using `tar -cf`
4. **Manifest**: Generates a JSON manifest with checksums, stored both locally and on the tape system

### Example

```bash
./archive.sh \
  --source /mnt/data \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/backups/2026-07-02 \
  --min-size 100GB \
  --max-size 1TB \
  --threads 2
```

## archive-verify.sh

Verifies the integrity of archived tar files.

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--manifest PATH` | Yes | Path to manifest.json file |
| `--tape-host HOST` | Yes | SSH host for tape system |
| `--tape-path PATH` | Yes | Remote path on tape system |
| `--tar NAME` | No | Verify only a specific tar file |
| `--checksum` | No | Verify checksums (requires downloading tar files) |
| `--help` | No | Show usage information |

### Verification Levels

1. **Structure**: Validates tar file structure using `tar -tf`
2. **Contents**: Compares archived files against source (if accessible) using `tar -dv`
3. **Checksum**: Verifies SHA-256 checksums match the manifest

### Example

```bash
# Verify all archives with checksums
./archive-verify.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --checksum

# Verify a specific tar file
./archive-verify.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --tar archive_001.tar
```

## archive-restore.sh

Restores data from tape archives to a local filesystem.

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--manifest PATH` | Yes | Path to manifest.json file |
| `--tape-host HOST` | Yes | SSH host for tape system |
| `--tape-path PATH` | Yes | Remote path on tape system |
| `--destination PATH` | Yes | Local path to restore data to |
| `--all` | No | Restore all archives |
| `--tar NAME` | No | Restore a specific tar file |
| `--paths PATH [PATH...]` | No | Restore specific paths from the selected tar |
| `--dry-run` | No | Show what would be restored without restoring |
| `--help` | No | Show usage information |

### Examples

```bash
# Restore all archives
./archive-restore.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --destination /data/restore \
  --all

# Restore a specific tar file
./archive-restore.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --destination /data/restore \
  --tar archive_001.tar

# Restore specific paths from a tar file
./archive-restore.sh \
  --manifest manifest.json \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --destination /data/restore \
  --tar archive_001.tar \
  --paths project_a/file.txt project_a/subdir
```

## archive-progress.sh

Checks the status of archives on the tape system.

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--tape-host HOST` | Yes | SSH host for tape system |
| `--tape-path PATH` | Yes | Remote path on tape system |
| `--list` | No | List all tar files |
| `--manifest` | No | Show manifest information |
| `--size` | No | Show size information for tar files |
| `--help` | No | Show usage information |

### Example

```bash
./archive-progress.sh \
  --tape-host admin@ranch.tacc.utexas.edu \
  --tape-path /mnt/tape/archive \
  --list --manifest --size
```

## Authentication

The scripts use standard SSH for authentication. Configure one of the following:

1. **SSH Keys (Recommended)**: Set up SSH key-based authentication with `ssh-agent`. This allows passwordless operation after initial key setup.

   ```bash
   # Generate SSH key (if needed)
   ssh-keygen -t ed25519 -C "your_email@example.com"

   # Add to ssh-agent
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519

   # Copy public key to tape system
   ssh-copy-id admin@ranch.tacc.utexas.edu
   ```

2. **Interactive Password/MFA**: If SSH keys are not configured, SSH will prompt interactively for your password and MFA token when you run the scripts from a terminal.

## Manifest Format

The manifest (`manifest.json`) contains metadata about the archive:

```json
{
  "version": "1.0",
  "created": "2026-07-02T10:30:00Z",
  "source_root": "/data",
  "tape_host": "admin@ranch.tacc.utexas.edu",
  "tape_path": "/mnt/tape/archive",
  "archive_sets": [
    {
      "tarfile": "archive_001.tar",
      "source_paths": "project_a,project_b,project_c",
      "size_bytes": 847000000000,
      "size_gb": 847,
      "checksum": "sha256:abc123...",
      "timestamp": "2026-07-02T10:30:00Z"
    }
  ]
}
```

## Logging

All scripts log to both stdout and a log file:

- `archive.sh`: `archive.log`
- `archive-verify.sh`: `archive-verify.log`
- `archive-restore.sh`: `archive-restore.log`
- `archive-progress.sh`: `archive-progress.log`

Log format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`

## Requirements

- Bash 4.0+
- `ssh` (OpenSSH)
- `tar` (GNU tar recommended)
- `jq` (for JSON processing)
- `sha256sum` (for checksums)

## Notes

- The archive process does not support resume. If interrupted, restart from the beginning.
- Directory structure is preserved at the top levels. Each tar file contains the original subdirectory names.
- Tar files are named `archive_001.tar`, `archive_002.tar`, etc.
- The manifest is stored both locally and on the tape system for redundancy.