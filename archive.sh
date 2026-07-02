#!/bin/bash
set -euo pipefail

LOG_FILE="archive.log"
MANIFEST_LOCAL="manifest.json"
MANIFEST_TMP=$(mktemp)
THREADS=1
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $(basename "$0") --source PATH --tape-host HOST --tape-path PATH --min-size SIZE --max-size SIZE [OPTIONS]

Archive large directory structures to a tape system via SSH.

Required arguments:
  --source PATH           Source directory to archive (absolute path)
  --tape-host HOST        SSH host for tape system (user@host)
  --tape-path PATH        Remote path on tape system for tar files
  --min-size SIZE         Minimum tar file size (e.g., 100GB, 500G)
  --max-size SIZE         Maximum tar file size (e.g., 1TB, 1024G)

Options:
  --threads N             Number of parallel tar operations (default: 1)
  --dry-run               Show what would be archived without creating tar files
  --help                  Show this help message

Examples:
  $(basename "$0") --source /data --tape-host admin@tape.example.com --tape-path /mnt/tape/archive --min-size 100GB --max-size 1TB
  $(basename "$0") --source /data --tape-host admin@tape.example.com --tape-path /mnt/tape/archive --min-size 100GB --max-size 1TB --threads 4 --dry-run
EOF
    exit "${1:-0}"
}

log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

parse_size() {
    local size="$1"
    local value unit
    value=$(echo "$size" | sed 's/[A-Za-z]//g')
    unit=$(echo "$size" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

    case "$unit" in
        TB|T)
            echo "$value * 1000 * 1000 * 1000 * 1000" | bc
            ;;
        GB|G)
            echo "$value * 1000 * 1000 * 1000" | bc
            ;;
        MB|M)
            echo "$value * 1000 * 1000" | bc
            ;;
        KB|K)
            echo "$value * 1000" | bc
            ;;
        B|"")
            echo "$value" | bc
            ;;
        *)
            log "ERROR" "Unknown size unit: $unit"
            exit 1
            ;;
    esac
}

get_dir_size() {
    local dir="$1"
    du -sb "$dir" 2>/dev/null | awk '{print $1}' || echo 0
}

ssh_cmd() {
    ssh -o StrictHostKeyChecking=no -o BatchMode=no "$TAPE_HOST"
}

ssh_pass() {
    local cmd="$1"
    if [[ -n "${SSH_PASSWORD:-}" ]]; then
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$TAPE_HOST" "$cmd"
    else
        sshpass -d 0 ssh -o StrictHostKeyChecking=no "$TAPE_HOST" "$cmd"
    fi
}

ssh_pass_mkdir() {
    local dir="$1"
    ssh_pass "mkdir -p '$dir'"
}

scp_to_remote() {
    local local_file="$1"
    local remote_file="$2"
    if [[ -n "${SSH_PASSWORD:-}" ]]; then
        sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no "$local_file" "$TAPE_HOST:$remote_file"
    else
        sshpass -d 0 scp -o StrictHostKeyChecking=no "$local_file" "$TAPE_HOST:$remote_file"
    fi
}

calculate_checksum() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

group_directories() {
    local source_root="$1"
    local min_bytes="$2"
    local max_bytes="$3"

    local groups=()
    local current_group=()
    local current_size=0

    for dir in "$source_root"/*/; do
        [[ -d "$dir" ]] || continue
        local dir_name=$(basename "$dir")
        local dir_size=$(get_dir_size "$dir")

        if [[ $dir_size -eq 0 ]]; then
            log "WARN" "Skipping empty directory: $dir_name"
            continue
        fi

        if [[ ${#current_group[@]} -eq 0 ]]; then
            current_group=("$dir_name")
            current_size=$dir_size
        elif [[ $((current_size + dir_size)) -le $max_bytes ]] && [[ $current_size -lt $min_bytes ]]; then
            current_group+=("$dir_name")
            current_size=$((current_size + dir_size))
        else
            if [[ $current_size -ge $min_bytes ]] || [[ ${#current_group[@]} -eq 1 ]]; then
                groups+=("${current_group[*]}")
            else
                current_group+=("$dir_name")
                current_size=$((current_size + dir_size))
                groups+=("${current_group[*]}")
                current_group=()
                current_size=0
            fi
        fi
    done

    if [[ ${#current_group[@]} -gt 0 ]]; then
        groups+=("${current_group[*]}")
    fi

    printf '%s\n' "${groups[@]}"
}

create_tar_over_ssh() {
    local group_dirs="$1"
    local tar_name="$2"
    local source_root="$3"
    local tape_path="$4"

    local remote_tar="$tape_path/$tar_name"
    local remote_dir=$(dirname "$remote_tar")

    log "INFO" "Creating tar: $tar_name"
    log "INFO" "  Directories: $group_dirs"
    log "INFO" "  Remote path: $remote_tar"

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "  [DRY RUN] Would create tar over SSH"
        return 0
    fi

    ssh_pass_mkdir "$remote_dir"

    local tar_cmd="cd '$source_root' && tar -cf '$remote_tar'"
    for dir in $group_dirs; do
        tar_cmd+=" './$dir'"
    done
    tar_cmd+=" 2>&1"

    local output
    output=$(eval "$tar_cmd" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Failed to create $tar_name: $output"
        return $exit_code
    fi

    log "INFO" "Successfully created $tar_name"
    echo "$tar_name"
}

init_manifest() {
    cat > "$MANIFEST_TMP" <<'EOF'
{
  "version": "1.0",
  "created": "",
  "source_root": "",
  "tape_host": "",
  "tape_path": "",
  "archive_sets": []
}
EOF
}

update_manifest() {
    local tar_file="$1"
    local source_paths="$2"
    local size_bytes="$3"
    local checksum="$4"

    local size_gb
    size_gb=$(echo "scale=2; $size_bytes / 1000 / 1000 / 1000" | bc)

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local entries=$(cat "$MANIFEST_TMP")
    local new_entry=$(cat <<EOF
    {
      "tarfile": "$tar_file",
      "source_paths": "$source_paths",
      "size_bytes": $size_bytes,
      "size_gb": $size_gb,
      "checksum": "$checksum",
      "timestamp": "$timestamp"
    }
EOF
)

    if [[ "$entries" == *"archive_sets"* ]]; then
        entries=$(echo "$entries" | jq --argjson entry "$new_entry" '.archive_sets += [$entry]')
    else
        entries=$(echo "$entries" | jq --argjson entry "$new_entry" '.archive_sets = [$entry]')
    fi

    echo "$entries" > "$MANIFEST_TMP"
}

finalize_manifest() {
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local entries=$(cat "$MANIFEST_TMP")
    entries=$(echo "$entries" | jq --arg timestamp "$timestamp" '.created = $timestamp')
    entries=$(echo "$entries" | jq --arg source_root "$SOURCE_ROOT" '.source_root = $source_root')
    entries=$(echo "$entries" | jq --arg tape_host "$TAPE_HOST" '.tape_host = $tape_host')
    entries=$(echo "$entries" | jq --arg tape_path "$TAPE_PATH" '.tape_path = $tape_path')

    echo "$entries" > "$MANIFEST_TMP"
}

main() {
    SOURCE_ROOT=""
    TAPE_HOST=""
    TAPE_PATH=""
    MIN_SIZE=""
    MAX_SIZE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                SOURCE_ROOT="$2"; shift 2 ;;
            --tape-host)
                TAPE_HOST="$2"; shift 2 ;;
            --tape-path)
                TAPE_PATH="$2"; shift 2 ;;
            --min-size)
                MIN_SIZE="$2"; shift 2 ;;
            --max-size)
                MAX_SIZE="$2"; shift 2 ;;
            --threads)
                THREADS="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --help)
                usage 0 ;;
            *)
                echo "Unknown option: $1"
                usage 1 ;;
        esac
    done

    if [[ -z "$SOURCE_ROOT" ]] || [[ -z "$TAPE_HOST" ]] || [[ -z "$TAPE_PATH" ]] || [[ -z "$MIN_SIZE" ]] || [[ -z "$MAX_SIZE" ]]; then
        echo "Error: Missing required arguments"
        usage 1
    fi

    if [[ ! -d "$SOURCE_ROOT" ]]; then
        log "ERROR" "Source directory does not exist: $SOURCE_ROOT"
        exit 1
    fi

    log "INFO" "=========================================="
    log "INFO" "Archive Process Started"
    log "INFO" "=========================================="
    log "INFO" "Source: $SOURCE_ROOT"
    log "INFO" "Tape Host: $TAPE_HOST"
    log "INFO" "Tape Path: $TAPE_PATH"
    log "INFO" "Min Size: $MIN_SIZE"
    log "INFO" "Max Size: $MAX_SIZE"
    log "INFO" "Threads: $THREADS"

    local min_bytes
    min_bytes=$(parse_size "$MIN_SIZE")
    local max_bytes
    max_bytes=$(parse_size "$MAX_SIZE")

    log "INFO" "Min Bytes: $min_bytes"
    log "INFO" "Max Bytes: $max_bytes"

    init_manifest

    log "INFO" "Scanning source directory..."
    local groups
    groups=$(group_directories "$SOURCE_ROOT" "$min_bytes" "$max_bytes")

    if [[ -z "$groups" ]]; then
        log "ERROR" "No directories to archive"
        exit 1
    fi

    local group_count
    group_count=$(echo "$groups" | wc -l)
    log "INFO" "Created $group_count archive sets"

    local tar_index=1
    while IFS= read -r group_dirs; do
        [[ -z "$group_dirs" ]] && continue

        local tar_name
        printf -v tar_name "archive_%03d.tar" "$tar_index"

        local tar_result
        tar_result=$(create_tar_over_ssh "$group_dirs" "$tar_name" "$SOURCE_ROOT" "$TAPE_PATH")

        if [[ $? -eq 0 ]] && [[ "$DRY_RUN" != true ]]; then
            local temp_tar="/tmp/${tar_name}"
            ssh_pass "cat $TAPE_PATH/$tar_name" > "$temp_tar"
            local checksum
            checksum=$(calculate_checksum "$temp_tar")
            local size_bytes
            size_bytes=$(stat -f%z "$temp_tar" 2>/dev/null || stat -c%s "$temp_tar" 2>/dev/null)
            rm -f "$temp_tar"

            update_manifest "$tar_name" "$group_dirs" "$size_bytes" "$checksum"
        fi

        ((tar_index++))
    done <<< "$groups"

    finalize_manifest

    log "INFO" "Copying manifest to tape system..."
    if [[ "$DRY_RUN" != true ]]; then
        scp_to_remote "$MANIFEST_TMP" "$TAPE_PATH/$MANIFEST_LOCAL"
        cp "$MANIFEST_TMP" "./$MANIFEST_LOCAL"
        log "INFO" "Manifest saved locally as $MANIFEST_LOCAL"
    fi

    log "INFO" "=========================================="
    log "INFO" "Archive Process Completed"
    log "INFO" "=========================================="

    rm -f "$MANIFEST_TMP"
}

main "$@"