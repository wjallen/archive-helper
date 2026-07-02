#!/bin/bash
set -euo pipefail

LOG_FILE="archive-verify.log"
MANIFEST_LOCAL="manifest.json"

usage() {
    cat <<EOF
Usage: $(basename "$0") --manifest PATH --tape-host HOST --tape-path PATH [OPTIONS]

Verify archive integrity against the manifest.

Required arguments:
  --manifest PATH         Path to manifest.json file
  --tape-host HOST        SSH host for tape system (user@host)
  --tape-path PATH        Remote path on tape system where tar files are stored

Options:
  --tar NAME              Verify only a specific tar file (default: all)
  --checksum              Verify checksums of tar files (requires downloading)
  --help                  Show this help message

Examples:
  $(basename "$0") --manifest manifest.json --tape-host admin@ranch.tacc.utexas.edu --tape-path /mnt/tape/archive
  $(basename "$0") --manifest manifest.json --tape-host admin@ranch.tacc.utexas.edu --tape-path /mnt/tape/archive --tar archive_001.tar
  $(basename "$0") --manifest manifest.json --tape-host admin@ranch.tacc.utexas.edu --tape-path /mnt/tape/archive --checksum
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
    ssh -o StrictHostKeyChecking=no "$TAPE_HOST" "$cmd"
}

scp_from_remote() {
    local remote_file="$1"
    local local_file="$2"
    scp -o StrictHostKeyChecking=no "$TAPE_HOST:$remote_file" "$local_file"
}

calculate_checksum() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

verify_tar_structure() {
    local tar_path="$1"
    local tar_name=$(basename "$tar_path")

    log "INFO" "Verifying tar structure: $tar_name"

    local output
    output=$(ssh_pass "tar -tf '$tar_path' 2>&1")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Tar structure verification failed for $tar_name: $output"
        return 1
    fi

    local file_count
    file_count=$(echo "$output" | wc -l)
    log "INFO" "  Structure OK - $file_count entries"
    return 0
}

verify_tar_contents() {
    local tar_path="$1"
    local tar_name=$(basename "$tar_path")

    log "INFO" "Verifying tar contents: $tar_name"

    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_tar="$temp_dir/$tar_name"

    scp_from_remote "$tar_path" "$temp_tar"

    local output
    output=$(tar -dvf "$temp_tar" 2>&1)
    local exit_code=$?

    rm -rf "$temp_dir"

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Tar contents verification failed for $tar_name"
        log "ERROR" "$output"
        return 1
    fi

    log "INFO" "  Contents OK"
    return 0
}

verify_checksum() {
    local tar_path="$1"
    local expected_checksum="$2"
    local tar_name=$(basename "$tar_path")

    log "INFO" "Verifying checksum: $tar_name"

    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_tar="$temp_dir/$tar_name"

    scp_from_remote "$tar_path" "$temp_tar"

    local actual_checksum
    actual_checksum=$(calculate_checksum "$temp_tar")

    rm -rf "$temp_dir"

    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        log "ERROR" "Checksum mismatch for $tar_name"
        log "ERROR" "  Expected: $expected_checksum"
        log "ERROR" "  Actual:   $actual_checksum"
        return 1
    fi

    log "INFO" "  Checksum OK"
    return 0
}

main() {
    MANIFEST_PATH=""
    TAPE_HOST=""
    TAPE_PATH=""
    SINGLE_TAR=""
    VERIFY_CHECKSUM=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manifest)
                MANIFEST_PATH="$2"; shift 2 ;;
            --tape-host)
                TAPE_HOST="$2"; shift 2 ;;
            --tape-path)
                TAPE_PATH="$2"; shift 2 ;;
            --tar)
                SINGLE_TAR="$2"; shift 2 ;;
            --checksum)
                VERIFY_CHECKSUM=true; shift ;;
            --help)
                usage 0 ;;
            *)
                echo "Unknown option: $1"
                usage 1 ;;
        esac
    done

    if [[ -z "$MANIFEST_PATH" ]] || [[ -z "$TAPE_HOST" ]] || [[ -z "$TAPE_PATH" ]]; then
        echo "Error: Missing required arguments"
        usage 1
    fi

    if [[ ! -f "$MANIFEST_PATH" ]]; then
        log "ERROR" "Manifest file not found: $MANIFEST_PATH"
        exit 1
    fi

    log "INFO" "=========================================="
    log "INFO" "Archive Verification Started"
    log "INFO" "=========================================="
    log "INFO" "Manifest: $MANIFEST_PATH"
    log "INFO" "Tape Host: $TAPE_HOST"
    log "INFO" "Tape Path: $TAPE_PATH"

    local manifest_source_root
    manifest_source_root=$(jq -r '.source_root' "$MANIFEST_PATH")
    local manifest_tape_host
    manifest_tape_host=$(jq -r '.tape_host' "$MANIFEST_PATH")
    local manifest_tape_path
    manifest_tape_path=$(jq -r '.tape_path' "$MANIFEST_PATH")

    log "INFO" "Archive created from: $manifest_source_root"
    log "INFO" "Archive stored at: ${manifest_tape_host}:${manifest_tape_path}"

    local tar_files
    if [[ -n "$SINGLE_TAR" ]]; then
        tar_files=$(jq -r --arg tar "$SINGLE_TAR" '.archive_sets[] | select(.tarfile == $tar)' "$MANIFEST_PATH")
        if [[ -z "$tar_files" ]]; then
            log "ERROR" "Tar file $SINGLE_TAR not found in manifest"
            exit 1
        fi
    else
        tar_files=$(jq -r '.archive_sets[] | @base64' "$MANIFEST_PATH")
    fi

    local total=0
    local passed=0
    local failed=0

    if [[ -n "$SINGLE_TAR" ]]; then
        total=1
        local tarfile=$(jq -r --arg tar "$SINGLE_TAR" '.archive_sets[] | select(.tarfile == $tar) | .tarfile' "$MANIFEST_PATH")
        local checksum=$(jq -r --arg tar "$SINGLE_TAR" '.archive_sets[] | select(.tarfile == $tar) | .checksum' "$MANIFEST_PATH")
        local remote_path="$TAPE_PATH/$tarfile"

        if verify_tar_structure "$remote_path"; then
            ((passed++))
        else
            ((failed++))
        fi

        if [[ "$VERIFY_CHECKSUM" == true ]]; then
            if verify_checksum "$remote_path" "$checksum"; then
                ((passed++))
            else
                ((failed++))
            fi
        fi
    else
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            ((total++))

            local data
            data=$(echo "$entry" | base64 -d)
            local tarfile
            tarfile=$(echo "$data" | jq -r '.tarfile')
            local checksum
            checksum=$(echo "$data" | jq -r '.checksum')
            local remote_path="$TAPE_PATH/$tarfile"

            log "INFO" "----------------------------------------"
            log "INFO" "Verifying: $tarfile"

            if verify_tar_structure "$remote_path"; then
                ((passed++))
            else
                ((failed++))
            fi

            if [[ "$VERIFY_CHECKSUM" == true ]]; then
                if verify_checksum "$remote_path" "$checksum"; then
                    ((passed++))
                else
                    ((failed++))
                fi
            fi
        done <<< "$tar_files"
    fi

    log "INFO" "=========================================="
    log "INFO" "Verification Summary"
    log "INFO" "=========================================="
    log "INFO" "Total checks: $total"
    log "INFO" "Passed: $passed"
    log "INFO" "Failed: $failed"

    if [[ $failed -gt 0 ]]; then
        log "ERROR" "Verification completed with failures"
        exit 1
    else
        log "INFO" "Verification completed successfully"
        exit 0
    fi
}

main "$@"