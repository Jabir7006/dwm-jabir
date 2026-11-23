#!/bin/bash

if pgrep -f 'hostapd.*(/etc/hostapd/localsend\.conf|localsend\.conf)' >/dev/null 2>&1; then
    echo "󰀂 ON"
else
    echo "󰀂 OFF"
fi
