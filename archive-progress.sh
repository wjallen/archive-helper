#!/bin/bash

LOG_FILE="archive-progress.log"

usage() {
    cat <<'ENDOFUSAGE'
Usage: archive-progress.sh --tape-host HOST --tape-path PATH [OPTIONS]

Check progress of running archive operations on the tape system.

Required arguments:
  --tape-host HOST        SSH host for tape system (user@host)
  --tape-path PATH        Remote path on tape system where tar files are stored

Options:
  --list                  List all tar files in the tape path
  --manifest              Show manifest information if available
  --size                  Show size information for tar files
  --help                  Show this help message

Examples:
  archive-progress.sh --tape-host admin@tape.example.com --tape-path /mnt/tape/archive
  archive-progress.sh --tape-host admin@tape.example.com --tape-path /mnt/tape/archive --list --size
ENDOFUSAGE
    exit "${1:-0}"
}

log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

ssh_cmd() {
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

list_tar_files() {
    log "INFO" "Listing tar files in $TAPE_PATH"
    ssh_cmd "ls -lh $TAPE_PATH/"*.tar 2>/dev/null || echo "No tar files found"
}

show_manifest() {
    local manifest_remote="$TAPE_PATH/manifest.json"

    log "INFO" "Fetching manifest from tape system..."

    local temp_manifest
    temp_manifest=$(mktemp)

    scp_from_remote "$manifest_remote" "$temp_manifest" 2>/dev/null

    if [[ ! -f "$temp_manifest" ]] || [[ ! -s "$temp_manifest" ]]; then
        log "WARN" "No manifest found on tape system"
        return 1
    fi

    log "INFO" "=========================================="
    log "INFO" "Manifest Contents"
    log "INFO" "=========================================="

    local version created source_root tape_host tape_path
    version=$(jq -r '.version' "$temp_manifest")
    created=$(jq -r '.created' "$temp_manifest")
    source_root=$(jq -r '.source_root' "$temp_manifest")
    tape_host=$(jq -r '.tape_host' "$temp_manifest")
    tape_path=$(jq -r '.tape_path' "$temp_manifest")

    log "INFO" "Version: $version"
    log "INFO" "Created: $created"
    log "INFO" "Source Root: $source_root"
    log "INFO" "Tape Host: $tape_host"
    log "INFO" "Tape Path: $tape_path"

    local archive_count
    archive_count=$(jq '.archive_sets | length' "$temp_manifest")
    log "INFO" "Archive Sets: $archive_count"

    echo ""
    printf "%-20s %10s %15s %s\n" "TARFILE" "SIZE_GB" "CHECKSUM" "SOURCE_PATHS"
    printf "%-20s %10s %15s %s\n" "-------" "------" "--------" "-----------"

    local entries
    entries=$(jq -c '.archive_sets[]' "$temp_manifest")
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local tarfile size_gb checksum source_paths
        tarfile=$(echo "$entry" | jq -r '.tarfile')
        size_gb=$(echo "$entry" | jq -r '.size_gb')
        checksum=$(echo "$entry" | jq -r '.checksum' | cut -c1-12)
        source_paths=$(echo "$entry" | jq -r '.source_paths')
        printf "%-20s %10s %15s %s\n" "$tarfile" "$size_gb" "$checksum" "$source_paths"
    done <<< "$entries"

    rm -f "$temp_manifest"
}

show_sizes() {
    log "INFO" "Calculating sizes of tar files..."

    local temp_sizes
    temp_sizes=$(ssh_cmd "du -sh $TAPE_PATH/"*.tar 2>/dev/null | sort -h)

    if [[ -z "$temp_sizes" ]]; then
        log "WARN" "No tar files found"
        return
    fi

    echo ""
    printf "%s\n" "$temp_sizes"

    local total
    total=$(echo "$temp_sizes" | awk '{sum+=$1} END {print sum}')
    log "INFO" "Total size: $total"
}

main() {
    TAPE_HOST=""
    TAPE_PATH=""
    LIST_FILES=false
    SHOW_MANIFEST=false
    SHOW_SIZES=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tape-host)
                TAPE_HOST="$2"; shift 2 ;;
            --tape-path)
                TAPE_PATH="$2"; shift 2 ;;
            --list)
                LIST_FILES=true; shift ;;
            --manifest)
                SHOW_MANIFEST=true; shift ;;
            --size)
                SHOW_SIZES=true; shift ;;
            --help)
                usage 0 ;;
            *)
                echo "Unknown option: $1"
                usage 1 ;;
        esac
    done

    if [[ -z "$TAPE_HOST" ]] || [[ -z "$TAPE_PATH" ]]; then
        echo "Error: Missing required arguments"
        usage 1
    fi

    if [[ "$LIST_FILES" == false ]] && [[ "$SHOW_MANIFEST" == false ]] && [[ "$SHOW_SIZES" == false ]]; then
        LIST_FILES=true
        SHOW_MANIFEST=true
        SHOW_SIZES=true
    fi

    log "INFO" "=========================================="
    log "INFO" "Archive Progress Check"
    log "INFO" "=========================================="
    log "INFO" "Tape Host: $TAPE_HOST"
    log "INFO" "Tape Path: $TAPE_PATH"

    if [[ "$LIST_FILES" == true ]]; then
        echo ""
        list_tar_files
    fi

    if [[ "$SHOW_MANIFEST" == true ]]; then
        echo ""
        show_manifest
    fi

    if [[ "$SHOW_SIZES" == true ]]; then
        show_sizes
    fi
}

main "$@"