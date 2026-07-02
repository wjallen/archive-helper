#!/bin/bash
set -euo pipefail

LOG_FILE="archive-restore.log"

usage() {
    cat <<EOF
Usage: $(basename "$0") --manifest PATH --tape-host HOST --tape-path PATH --destination PATH [OPTIONS]

Restore data from tape archives.

Required arguments:
  --manifest PATH         Path to manifest.json file
  --tape-host HOST        SSH host for tape system (user@host)
  --tape-path PATH        Remote path on tape system where tar files are stored
  --destination PATH      Local path to restore data to

Options:
  --all                   Restore all archives (default if no --tar specified)
  --tar NAME              Restore a specific tar file only
  --paths PATH [PATH...]  Restore specific paths from the selected tar file
  --dry-run               Show what would be restored without restoring
  --help                  Show this help message

Examples:
  $(basename "$0") --manifest manifest.json --tape-host admin@tape.example.com --tape-path /mnt/tape/archive --destination /restore/path --all
  $(basename "$0") --manifest manifest.json --tape-host admin@tape.example.com --tape-path /mnt/tape/archive --destination /restore/path --tar archive_001.tar
  $(basename "$0") --manifest manifest.json --tape-host admin@tape.example.com --tape-path /mnt/tape/archive --destination /restore/path --tar archive_001.tar --paths project_a/file.txt project_a/subdir
EOF
    exit "${1:-0}"
}

log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

ssh_pass() {
    local cmd="$1"
    if [[ -n "${SSH_PASSWORD:-}" ]]; then
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$TAPE_HOST" "$cmd"
    else
        sshpass -d 0 ssh -o StrictHostKeyChecking=no "$TAPE_HOST" "$cmd"
    fi
}

scp_from_remote() {
    local remote_file="$1"
    local local_file="$2"
    if [[ -n "${SSH_PASSWORD:-}" ]]; then
        sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no "$TAPE_HOST:$remote_file" "$local_file"
    else
        sshpass -d 0 scp -o StrictHostKeyChecking=no "$TAPE_HOST:$remote_file" "$local_file"
    fi
}

restore_full_tar() {
    local tar_path="$1"
    local destination="$2"
    local tar_name=$(basename "$tar_path")

    log "INFO" "Restoring full tar: $tar_name"

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "  [DRY RUN] Would restore $tar_name to $destination"
        return 0
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_tar="$temp_dir/$tar_name"

    scp_from_remote "$tar_path" "$temp_tar"

    mkdir -p "$destination"

    local output
    output=$(tar -xf "$temp_tar" -C "$destination" 2>&1)
    local exit_code=$?

    rm -rf "$temp_dir"

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Failed to restore $tar_name: $output"
        return 1
    fi

    log "INFO" "  Successfully restored $tar_name"
    return 0
}

restore_paths_from_tar() {
    local tar_path="$1"
    local destination="$2"
    local paths="$3"
    local tar_name=$(basename "$tar_path")

    log "INFO" "Restoring paths from: $tar_name"
    log "INFO" "  Paths: $paths"

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "  [DRY RUN] Would restore paths from $tar_name to $destination"
        return 0
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_tar="$temp_dir/$tar_name"

    scp_from_remote "$tar_path" "$temp_tar"

    mkdir -p "$destination"

    local tar_cmd="tar -xf '$temp_tar' -C '$destination'"
    for path in $paths; do
        tar_cmd+=" '$path'"
    done

    local output
    output=$(eval "$tar_cmd" 2>&1)
    local exit_code=$?

    rm -rf "$temp_dir"

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Failed to restore paths from $tar_name: $output"
        return 1
    fi

    log "INFO" "  Successfully restored paths from $tar_name"
    return 0
}

list_tar_contents() {
    local tar_path="$1"
    ssh_pass "tar -tf '$tar_path'"
}

main() {
    MANIFEST_PATH=""
    TAPE_HOST=""
    TAPE_PATH=""
    DESTINATION=""
    RESTORE_ALL=false
    SINGLE_TAR=""
    RESTORE_PATHS=""
    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manifest)
                MANIFEST_PATH="$2"; shift 2 ;;
            --tape-host)
                TAPE_HOST="$2"; shift 2 ;;
            --tape-path)
                TAPE_PATH="$2"; shift 2 ;;
            --destination)
                DESTINATION="$2"; shift 2 ;;
            --all)
                RESTORE_ALL=true; shift ;;
            --tar)
                SINGLE_TAR="$2"; shift 2 ;;
            --paths)
                shift
                RESTORE_PATHS="$*"
                break ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --help)
                usage 0 ;;
            *)
                echo "Unknown option: $1"
                usage 1 ;;
        esac
    done

    if [[ -z "$MANIFEST_PATH" ]] || [[ -z "$TAPE_HOST" ]] || [[ -z "$TAPE_PATH" ]] || [[ -z "$DESTINATION" ]]; then
        echo "Error: Missing required arguments"
        usage 1
    fi

    if [[ ! -f "$MANIFEST_PATH" ]]; then
        log "ERROR" "Manifest file not found: $MANIFEST_PATH"
        exit 1
    fi

    if [[ "$RESTORE_ALL" == false ]] && [[ -z "$SINGLE_TAR" ]]; then
        echo "Error: Must specify either --all or --tar"
        usage 1
    fi

    log "INFO" "=========================================="
    log "INFO" "Archive Restore Started"
    log "INFO" "=========================================="
    log "INFO" "Manifest: $MANIFEST_PATH"
    log "INFO" "Tape Host: $TAPE_HOST"
    log "INFO" "Tape Path: $TAPE_PATH"
    log "INFO" "Destination: $DESTINATION"

    if [[ -n "$SINGLE_TAR" ]]; then
        local tar_entry
        tar_entry=$(jq -r --arg tar "$SINGLE_TAR" '.archive_sets[] | select(.tarfile == $tar)' "$MANIFEST_PATH")

        if [[ -z "$tar_entry" ]] || [[ "$tar_entry" == "null" ]]; then
            log "ERROR" "Tar file $SINGLE_TAR not found in manifest"
            exit 1
        fi

        local remote_path="$TAPE_PATH/$SINGLE_TAR"

        if [[ -n "$RESTORE_PATHS" ]]; then
            restore_paths_from_tar "$remote_path" "$DESTINATION" "$RESTORE_PATHS"
        else
            restore_full_tar "$remote_path" "$DESTINATION"
        fi
    else
        local tar_files
        tar_files=$(jq -r '.archive_sets[] | @base64' "$MANIFEST_PATH")

        local count=0
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            ((count++))

            local data
            data=$(echo "$entry" | base64 -d)
            local tarfile
            tarfile=$(echo "$data" | jq -r '.tarfile')
            local remote_path="$TAPE_PATH/$tarfile"

            log "INFO" "----------------------------------------"
            log "INFO" "Restoring ($count): $tarfile"

            restore_full_tar "$remote_path" "$DESTINATION"
        done <<< "$tar_files"

        log "INFO" "Restored $count archive sets"
    fi

    log "INFO" "=========================================="
    log "INFO" "Restore Completed"
    log "INFO" "=========================================="
}

main "$@"