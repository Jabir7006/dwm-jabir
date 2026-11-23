#!/bin/bash

# Current brightness percentage ber kora
current=$(brightnessctl -m | awk -F, '{print substr($4, 1, length($4)-1)}')

# Modern Standard Horizontal Slider
yad --scale \
    --class="YadSlider" \
    --title="Brightness Control" \
    --value="$current" \
    --width=450 \
    --height=100 \
    --center \
    --print-partial \
    --button="yad-close:0" | while read -r val; do
        brightnessctl set "${val}%"
    done