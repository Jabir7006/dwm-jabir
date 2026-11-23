#!/bin/bash

# Available sink gulo (audio outputs) list kora
mapfile -t sinks < <(pactl list short sinks | awk '{print $2}')

# Ekta matro output thakle toggle korar kono proyojon nai
if [ ${#sinks[@]} -le 1 ]; then
    exit 0
fi

# Current default sink ber kora
current_sink=$(pactl get-default-sink)

# Current sink-er index ber kora
index=0
for i in "${!sinks[@]}"; do
    if [ "${sinks[$i]}" == "$current_sink" ]; then
        index=$i
        break
    fi
done

# Next sink calculate kora (cycle korar jonno)
next_index=$(( (index + 1) % ${#sinks[@]} ))
next_sink="${sinks[$next_index]}"

# Notun sink-ke default hishebe set kora
pactl set-default-sink "$next_sink"

# Je audio gulo currently play hocche, sheguloke notun output-e move kora
mapfile -t inputs < <(pactl list short sink-inputs | awk '{print $1}')
for i in "${inputs[@]}"; do
    pactl move-sink-input "$i" "$next_sink"
done

# Notun audio device-er ashol nam (Description) ber kora jate dekhte valo lage
sink_desc=$(pactl list sinks | grep -A 10 "Name: $next_sink" | grep "Description:" | head -n 1 | sed 's/^[ \t]*Description:[ \t]*//')

# Desktop notification pathano
notify-send -t 2500 -i audio-volume-high "Audio Output Changed" "$sink_desc"