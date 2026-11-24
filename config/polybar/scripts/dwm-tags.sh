#!/bin/bash

# Omarchy's workspace style: small regular numbers, a rounded-square active
# glyph, and half-opacity empty slots. All updates still use the same X events.
COLOR_ACTIVE="${DWM_TAG_FOREGROUND:-${DWM_TAG_ACTIVE_COLOR:-#eceff4}}"
COLOR_OCCUPIED="${DWM_TAG_FOREGROUND:-${DWM_TAG_OCCUPIED_COLOR:-#d8dee9}}"
COLOR_URGENT="${DWM_TAG_URGENT_COLOR:-#bf616a}"
COLOR_EMPTY="${DWM_TAG_EMPTY_COLOR:-#80${COLOR_OCCUPIED#\#}}"
FONT_ACTIVE="${DWM_TAG_ACTIVE_FONT:-18}"
FONT_OCCUPIED="${DWM_TAG_OCCUPIED_FONT:-15}"
FONT_URGENT="${DWM_TAG_URGENT_FONT:-15}"
ACTIVE_ICON="${DWM_TAG_ACTIVE_ICON:-󱓻}"
PERSISTENT_COUNT="${DWM_TAG_PERSISTENT_COUNT:-5}"

# Function to generate and output the tag display
update_tags() {

# Get all client windows from EWMH (much faster than xdotool)
declare -A occupied_tags
declare -A urgent_tags
client_list=$(xprop -root _NET_CLIENT_LIST 2>/dev/null | cut -d'#' -f2)

if [ -n "$client_list" ]; then
    # Parse window IDs and query their desktops
    for win_id in $(echo "$client_list" | tr ',' '\n' | tr -d ' '); do
        if [ -n "$win_id" ]; then
            desktop=$(xprop -id "$win_id" _NET_WM_DESKTOP 2>/dev/null | awk '{print $3}')
            # Skip if not set or is 4294967295 (sticky/all desktops)
            if [ -n "$desktop" ] && [ "$desktop" != "4294967295" ]; then
                occupied_tags[$desktop]=1
                
                # Check for urgent hint
                hints=$(xprop -id "$win_id" WM_HINTS 2>/dev/null)
                if echo "$hints" | command grep -q "urgency hint"; then
                    urgent_tags[$desktop]=1
                fi
            fi
        fi
    done
fi

    # Get current desktop from all monitors
    current=$(xprop -root _NET_CURRENT_DESKTOP 2>/dev/null | awk '{print $3}')
    current=${current:-0}

    # Keep 1-5 visible, like Omarchy. Higher tags appear when active or in use.
    output=""
    for i in {0..8}; do
        tag=$((i + 1))
        symbol="$tag"
        if [ "$i" = "$current" ]; then
            symbol="$ACTIVE_ICON"
            color="$COLOR_ACTIVE"
            font="$FONT_ACTIVE"
        elif [ "${urgent_tags[$i]}" = "1" ]; then
            color="$COLOR_URGENT"
            font="$FONT_URGENT"
        elif [ "${occupied_tags[$i]}" = "1" ]; then
            color="$COLOR_OCCUPIED"
            font="$FONT_OCCUPIED"
        elif (( i < PERSISTENT_COUNT )); then
            color="$COLOR_EMPTY"
            font="$FONT_OCCUPIED"
        else
            continue
        fi
        # At 14px both number and active glyph advance 8px; fixed spacing
        # keeps each clickable workspace slot 26px wide.
        output+="%{A1:xdotool key super+$tag:}%{O8}%{F${color}}%{T${font}}$symbol%{T-}%{F-}%{O10}%{A}"
    done

    # Always output something, even if empty, to prevent polybar from breaking
    echo "${output:- }"
}

# Check if tail mode is enabled (for event-driven updates)
if [ "$1" = "--tail" ]; then
    # Output initial state
    update_tags
    
    # Listen for property changes that indicate desktop/tag changes
    # Monitors: DWM_TAG_UPDATE (custom signal), _NET_CURRENT_DESKTOP (active desktop), 
    # and _NET_CLIENT_LIST (window list changes)
    xprop -root -spy DWM_TAG_UPDATE _NET_CURRENT_DESKTOP _NET_CLIENT_LIST 2>/dev/null | \
    while read -r line; do
        update_tags
    done
else
    # Legacy polling mode - just run once
    update_tags
fi
