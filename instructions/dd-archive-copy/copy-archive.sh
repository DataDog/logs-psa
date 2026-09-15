#!/usr/bin/env bash
# copy-archive.sh
#
# Copies Datadog Log Archive files from a source S3 bucket into a destination
# S3 bucket. Preserves the dt=YYYYMMDD/hour=HH/ directory structure.
# Optionally restricts the copy to a date range.
#
# Usage:
#   ./copy-archive.sh [OPTIONS] <source-bucket> <dest-bucket>
#
# Options:
#   --dry-run              Preview what would be copied. No changes are made.
#   --start-date YYYYMMDD  Copy only files on or after this date (UTC).
#   --end-date   YYYYMMDD  Copy only files on or before this date (UTC).
#
# Environment variables:
#   AWS_ACCESS_KEY_ID     - required
#   AWS_SECRET_ACCESS_KEY - required
#   AWS_REGION            - optional, defaults to us-east-1
#
# Examples:
#   # Preview a full copy, no changes made
#   ./copy-archive.sh --dry-run kelnerhax2 kelnerhax
#
#   # Copy a specific date range
#   ./copy-archive.sh --start-date 20260915 --end-date 20260916 kelnerhax2 kelnerhax
#
#   # Copy everything from a date forward
#   ./copy-archive.sh --start-date 20260901 kelnerhax2 kelnerhax
#
#   # Copy everything up to a date
#   ./copy-archive.sh --end-date 20260930 kelnerhax2 kelnerhax
#
#   # Copy everything
#   ./copy-archive.sh kelnerhax2 kelnerhax

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
DRY_RUN=false
START_DATE=""
END_DATE=""

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --start-date)
            [[ -n "${2:-}" ]] || { echo "ERROR: --start-date requires a value (YYYYMMDD)" >&2; exit 1; }
            START_DATE="$2"
            [[ "$START_DATE" =~ ^[0-9]{8}$ ]] || { echo "ERROR: --start-date must be YYYYMMDD (e.g. 20260915)" >&2; exit 1; }
            shift 2
            ;;
        --end-date)
            [[ -n "${2:-}" ]] || { echo "ERROR: --end-date requires a value (YYYYMMDD)" >&2; exit 1; }
            END_DATE="$2"
            [[ "$END_DATE" =~ ^[0-9]{8}$ ]] || { echo "ERROR: --end-date must be YYYYMMDD (e.g. 20260916)" >&2; exit 1; }
            shift 2
            ;;
        -*)
            echo "ERROR: Unknown flag: $1" >&2
            echo "Usage: $0 [--dry-run] [--start-date YYYYMMDD] [--end-date YYYYMMDD] <source-bucket> <dest-bucket>" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

SOURCE="${1:-}"
DEST="${2:-}"

if [[ -z "$SOURCE" || -z "$DEST" ]]; then
    echo "Usage: $0 [--dry-run] [--start-date YYYYMMDD] [--end-date YYYYMMDD] <source-bucket> <dest-bucket>" >&2
    exit 1
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "ERROR: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set." >&2
    exit 1
fi

# Validate date ordering if both are provided
if [[ -n "$START_DATE" && -n "$END_DATE" && "$START_DATE" > "$END_DATE" ]]; then
    echo "ERROR: --start-date ($START_DATE) must be on or before --end-date ($END_DATE)" >&2
    exit 1
fi

# Build a human-readable date range label
if [[ -n "$START_DATE" && -n "$END_DATE" ]]; then
    DATE_RANGE="$START_DATE to $END_DATE"
elif [[ -n "$START_DATE" ]]; then
    DATE_RANGE="$START_DATE onward"
elif [[ -n "$END_DATE" ]]; then
    DATE_RANGE="up to $END_DATE"
else
    DATE_RANGE="all dates"
fi

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

SOURCE_ALL="$TMPDIR_WORK/source_all.txt"
SOURCE_FILTERED="$TMPDIR_WORK/source_filtered.txt"
DEST_ALL="$TMPDIR_WORK/dest_all.txt"
SOURCE_NAMES="$TMPDIR_WORK/source_names.txt"
DEST_NAMES="$TMPDIR_WORK/dest_names.txt"
DATES_FILE="$TMPDIR_WORK/dates.txt"

echo "=============================="
echo "Datadog Archive Copy"
echo "  Source     : s3://$SOURCE/"
echo "  Destination: s3://$DEST/"
echo "  Region     : $REGION"
echo "  Date range : $DATE_RANGE"
echo "  Dry run    : $DRY_RUN"
echo "=============================="
echo ""

# Step 1: Inventory source bucket
echo "[1/4] Inventorying source bucket..."
aws s3 ls "s3://$SOURCE/" --recursive --region "$REGION" \
    | awk '{print $NF}' \
    | grep -E '^dt=[0-9]{8}/hour=[0-9]+/archive_' \
    > "$SOURCE_ALL" || true

SOURCE_TOTAL=$(wc -l < "$SOURCE_ALL" | tr -d ' ')

# Apply date range filter
if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then
    > "$SOURCE_FILTERED"
    while IFS= read -r f; do
        dt=$(echo "$f" | grep -oE 'dt=[0-9]{8}' | head -1 | cut -d= -f2)
        [[ -z "$dt" ]] && continue
        [[ -n "$START_DATE" && "$dt" < "$START_DATE" ]] && continue
        [[ -n "$END_DATE"   && "$dt" > "$END_DATE"   ]] && continue
        echo "$f"
    done < "$SOURCE_ALL" > "$SOURCE_FILTERED"
    SOURCE_COUNT=$(wc -l < "$SOURCE_FILTERED" | tr -d ' ')
    echo "      $SOURCE_TOTAL total files in source; $SOURCE_COUNT match date range ($DATE_RANGE)"
else
    cp "$SOURCE_ALL" "$SOURCE_FILTERED"
    SOURCE_COUNT="$SOURCE_TOTAL"
    echo "      Found $SOURCE_COUNT archive files in s3://$SOURCE/"
fi

if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    echo ""
    echo "No source files found for the specified date range. Nothing to copy."
    exit 0
fi

# Step 2: Inventory destination bucket
echo "[2/4] Inventorying destination bucket..."
aws s3 ls "s3://$DEST/" --recursive --region "$REGION" \
    | awk '{print $NF}' \
    | grep -E '^dt=[0-9]{8}/hour=[0-9]+/archive_' \
    > "$DEST_ALL" || true

DEST_COUNT=$(wc -l < "$DEST_ALL" | tr -d ' ')
echo "      Found $DEST_COUNT archive files in s3://$DEST/"
echo ""

# Step 3: Collision check (compare filenames, not full paths)
echo "[3/4] Checking for filename collisions..."
awk -F'/' '{print $NF}' "$SOURCE_FILTERED" | sort > "$SOURCE_NAMES"
awk -F'/' '{print $NF}' "$DEST_ALL"        | sort > "$DEST_NAMES"

COLLISION_COUNT=$(comm -12 "$SOURCE_NAMES" "$DEST_NAMES" | wc -l | tr -d ' ')

if [[ "$COLLISION_COUNT" -gt 0 ]]; then
    echo "      WARNING: $COLLISION_COUNT file(s) with the same name exist in both buckets."
    echo "      These will be skipped (same-name, same-size files are not overwritten)."
    echo ""
    echo "      Colliding files:"
    comm -12 "$SOURCE_NAMES" "$DEST_NAMES" | sed 's/^/        /'
    echo ""
else
    echo "      No collisions found. All source files have unique names."
fi

FILES_TO_COPY=$((SOURCE_COUNT - COLLISION_COUNT))
echo "      Files to copy: $FILES_TO_COPY"
echo ""

# Build list of unique dt= partitions to sync
awk -F'/' '{for(i=1;i<=NF;i++) if($i ~ /^dt=[0-9]{8}$/) {print $i; break}}' "$SOURCE_FILTERED" \
    | sort -u > "$DATES_FILE"
DATE_PARTITION_COUNT=$(wc -l < "$DATES_FILE" | tr -d ' ')

# Step 4: Copy or dry run
if [[ "$DRY_RUN" == "true" ]]; then
    echo "[4/4] DRY RUN - files that would be copied:"
    echo ""
    while IFS= read -r dt; do
        echo "  [ $dt ]"
        aws s3 sync "s3://$SOURCE/$dt/" "s3://$DEST/$dt/" \
            --region "$REGION" \
            --exclude "*" \
            --include "hour=*/archive_*" \
            --dryrun
        echo ""
    done < "$DATES_FILE"
    echo "Dry run complete."
    echo "  $FILES_TO_COPY file(s) would be copied across $DATE_PARTITION_COUNT date partition(s)."
    echo "Run without --dry-run to perform the actual copy."
else
    echo "[4/4] Copying archive files ($DATE_PARTITION_COUNT date partition(s))..."
    while IFS= read -r dt; do
        echo "  Syncing $dt/..."
        aws s3 sync "s3://$SOURCE/$dt/" "s3://$DEST/$dt/" \
            --region "$REGION" \
            --exclude "*" \
            --include "hour=*/archive_*"
    done < "$DATES_FILE"

    echo ""
    echo "Copy complete. Verifying..."

    FINAL_COUNT=$(
        aws s3 ls "s3://$DEST/" --recursive --region "$REGION" \
            | awk '{print $NF}' \
            | grep -cE '^dt=[0-9]{8}/hour=[0-9]+/archive_' || true
    )

    EXPECTED_FINAL=$((DEST_COUNT + FILES_TO_COPY))

    echo ""
    echo "=============================="
    echo "Result"
    echo "  Files in destination before : $DEST_COUNT"
    echo "  Files copied                : $FILES_TO_COPY"
    echo "  Files in destination after  : $FINAL_COUNT"
    echo "  Expected total              : $EXPECTED_FINAL"
    echo "=============================="

    if [[ "$FINAL_COUNT" -ge "$EXPECTED_FINAL" ]]; then
        echo "SUCCESS"
    else
        echo "WARNING: Final count ($FINAL_COUNT) is less than expected ($EXPECTED_FINAL)."
        echo "Review the aws s3 sync output above for errors."
        exit 1
    fi
fi
