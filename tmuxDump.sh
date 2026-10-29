#!/usr/bin/env bash
set -euo pipefail

# List panes in all windows of the current session.
# Use -a instead of -s to include all sessions on this tmux server.
panes=$(tmux list-panes -s -F '#{pane_id} #{window_index} #{pane_index}')

# Create a unique directory in the current working directory.
OUT_DIR=$(mktemp -d "./tmux_dump_$(date +%Y%m%d_%H%M%S)_XXXXXX")
echo "Dumping panes to $OUT_DIR/..."

saved=0
failed=0

while read -r pane_id w_idx p_idx; do
    # Pane IDs make filenames unique without parsing window names.
    filename="$OUT_DIR/win_${w_idx}_pane_${p_idx}_id_${pane_id#%}.txt"

    # Capture all retained scrollback and the visible pane.
    if tmux capture-pane -p -S - -t "$pane_id" > "$filename"; then
        saved=$((saved + 1))
    else
        rm -f -- "$filename"
        echo "Failed to capture pane $pane_id" >&2
        failed=$((failed + 1))
    fi
done <<< "$panes"

echo "Saved $saved pane(s) to $OUT_DIR/; $failed failed."
(( failed == 0 ))
