# Archive-Helper Agents

## Repo Overview
Shell script suite for archiving large directory structures to tape via SSH. No external dependencies beyond standard tools.

## Scripts
- `archive.sh` - Create archives (auto-sizes into 100GB-1TB tar files)
- `archive-verify.sh` - Verify tar integrity and checksums
- `archive-restore.sh` - Restore full or partial archives
- `archive-progress.sh` - Check archive status on tape system

## Key Facts
- **Tape host**: `admin@ranch.tacc.utexas.edu`
- **Auth**: SSH keys (recommended) or interactive SSH password/MFA prompt
- **No sshpass/bc**: Scripts use pure bash arithmetic and plain `ssh`/`scp`
- **Manifest**: JSON at `manifest.json`, stored locally and on tape
- **No resume**: Interrupted archives must restart from scratch

## Requirements
- Bash 4.0+, ssh, tar, jq, sha256sum

## Common Tasks
```bash
# Archive data
./archive.sh --source /data --tape-host admin@ranch.tacc.utexas.edu --tape-path /mnt/tape/archive --min-size 100GB --max-size 1TB

# Verify with checksums
./archive-verify.sh --manifest manifest.json --tape-host admin@ranch.tacc.utexas.edu --tape-path /mnt/tape/archive --checksum

# Restore specific tar
./archive-restore.sh --manifest manifest.json --tape-host admin@ranch.tacc.utexas.edu --tape-path /mnt/tape/archive --destination /restore --tar archive_001.tar
```

## Size Format
Units: B, KB/K, MB/M, GB/G, TB/T (e.g., `100GB`, `1TB`). Pure integer math, no decimals.