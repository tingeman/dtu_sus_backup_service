#!/bin/sh

# Configuration file path (where we will mount the list of source/destination folders)
CONFIG_FILE="${1:-/backup/backup_folders.conf}"

# Check if the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Configuration file not found: $CONFIG_FILE"
  exit 1
fi

# Get the current timestamp (used for tarball filenames)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# List of sentinel files, one per mounted share (override with SENTINEL_FILE for tests)
SENTINEL_FILE="${SENTINEL_FILE:-/backup/sentinels.conf}"

# Read the operation and its arguments from the configuration file
while IFS=" " read -r OPERATION _ ARG1 _ ARG2 FILTER_KW FILTER_GLOB; do
  # Ignore lines starting with #
  if [ "${OPERATION#\#}" != "$OPERATION" ]; then
    continue
  fi

  # Ignore blank lines
  if [ -z "$OPERATION" ] && [ -z "$ARG1" ] && [ -z "$ARG2" ]; then
    continue
  fi

  # Refuse to run any job (and write nothing) if a mounted share is missing. Checked before
  # every job; cron jobs get no environment variables, so the list is read from a file.
  "$SCRIPT_DIR/check_sentinels.sh" "$SENTINEL_FILE" || {
    echo "Sentinel check failed, no further jobs will run (stopped before: $OPERATION $ARG1 $ARG2)"
    exit 1
  }

  # ==========================================================================
  # == Handle the different operations: COPY, TAR, RSYNC, PURGE             ==
  # ==========================================================================

  # Handle all other cases than PURGE first
  if [ "$OPERATION" != "PURGE" ]; then
    
    # ===== Handle the COPY, TAR, and RSYNC operations =====

    # Check if the line conforms to the expected layout
    if [ -z "$OPERATION" ] || [ -z "$ARG1" ] || [ -z "$ARG2" ]; then
      echo "Warning: Line does not conform to the expected layout: $OPERATION $ARG1 $ARG2"
      continue
    fi

    # Ensure source directory exists
    if [ ! -d "$ARG1" ]; then
      echo "Source directory not found: $ARG1"
      continue
    fi

    # Ensure the destination directory exists on the network drive
    DEST_PATH="$ARG2"
    mkdir -p "$DEST_PATH" || { echo "Failed to create destination directory: $DEST_PATH"; exit 1; }

    # Perform the operation based on the flag
    case $OPERATION in
      COPY)
        echo "Copying from $ARG1 to $DEST_PATH"
        cp -r "$ARG1"/* "$DEST_PATH/" || { echo "Copy failed"; exit 1; }
        ;;
      TAR)
        TAR_FILENAME="$DEST_PATH/$(basename "$ARG1")_$TIMESTAMP.tar.gz"
        echo "Creating tarball from $ARG1 to $TAR_FILENAME"
        tar -czf "$TAR_FILENAME" -C "$ARG1" . || { echo "Tarball creation failed"; exit 1; }
        ;;
      RSYNC)
        if [ -z "$FILTER_KW" ]; then
          echo "Synchronizing (rsync) from $ARG1 to $DEST_PATH"
          rsync -a --chmod=Dugo=rwx,Fugo=rw "$ARG1/" "$DEST_PATH/" || { echo "Rsync failed"; exit 1; }
        elif [ "$FILTER_KW" = "ONLY" ]; then
          # Optional filter: RSYNC FROM <src> TO <dst> ONLY <glob>
          # Copy only top-level files matching the glob; never *.partial or dot files,
          # and no subdirectories. The first matching rule wins, so order matters.
          GLOB="${FILTER_GLOB%\'}"; GLOB="${GLOB#\'}"
          GLOB="${GLOB%\"}"; GLOB="${GLOB#\"}"
          case "$GLOB" in
            ""|*/*|*" "*)
              echo "Warning: invalid ONLY pattern (empty, or contains / or space): $FILTER_GLOB"
              continue
              ;;
          esac
          echo "Synchronizing (rsync) from $ARG1 to $DEST_PATH, only top-level files matching $GLOB"
          rsync -a --chmod=Dugo=rwx,Fugo=rw \
            --exclude='/*.partial' --exclude='/.*' \
            --include="/$GLOB" --exclude='*' \
            "$ARG1/" "$DEST_PATH/" || { echo "Rsync failed"; exit 1; }
        else
          echo "Warning: unknown RSYNC option '$FILTER_KW' (expected ONLY <glob>), line skipped: $OPERATION $ARG1 $ARG2"
        fi
        ;;
      *)
        echo "Invalid operation specified: $OPERATION"
        ;;
    esac

    continue
  
  elif [ "$OPERATION" = "PURGE" ]; then

    # ===== Handle the PURGE operation =====

    # Check if the line conforms to the expected layout
    if [ -z "$OPERATION" ] || [ -z "$ARG1" ] || [ -z "$ARG2" ]; then
      echo "Warning: Line does not conform to the expected layout: $OPERATION $ARG1 $ARG2"
      continue
    fi

    # Ensure directory exists
    if [ ! -d "$ARG1" ]; then
      echo "Purge directory not found: $ARG1"
      continue
    fi

    # Check if the retention policy configuraton file exists
    if [ ! -f "$ARG2" ]; then
      echo "Retention policy file not found: $ARG2"
      continue
    fi

    # Perform the operation based on the flag
    echo "Purging files in $ARG1 using retention policy from $ARG2"
    python "$SCRIPT_DIR/apply_retention_policy.py" "$ARG1" "$ARG2" || {
        echo "Purge failed"
        exit 1
    }
    #python ./apply_retention_policy.py --dry_run "$ARG1" "$ARG2" || { echo "Purge failed"; exit 1; }
  fi

done < "$CONFIG_FILE" || { echo "Failed to read configuration file: $CONFIG_FILE"; exit 1; }
