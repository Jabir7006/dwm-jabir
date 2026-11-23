#!/bin/bash

# কিবোর্ডের নাম কনফিগারেশন
KBD_NAME_X11="AT Translated Set 2 keyboard"
KBD_NAME_WAYLAND="at-translated-set-2-keyboard"

# এরর হ্যান্ডেলিং ফাংশন
print_error() {
    echo -e "\e[31m[সমস্যা]\e[0m $1"
    exit 1
}

print_success() {
    echo -e "\e[32m[সফল]\e[0m $1"
}

# ডিসপ্লে সার্ভার সেশন টাইপ চেক করা
SESSION_TYPE=$XDG_SESSION_TYPE

if [ "$SESSION_TYPE" = "x11" ]; then
    # ১. X11 (dwm) এর জন্য লজিক
    
    # প্যাকেজ চেক
    if ! command -v xinput &> /dev/null; then
        print_error "xinput প্যাকেজটি ইন্সটল করা নেই! আর্চ লিনাক্সে টার্মিনালে রান করুন: sudo pacman -S xorg-xinput"
    fi

    # ডাইনামিক ID বের করা (যাতে রিস্টার্টের পর ID পরিবর্তন হলেও কাজ করে)
    KBD_ID=$(xinput list | grep -i "$KBD_NAME_X11" | grep -oP 'id=\K\d+')

    if [ -z "$KBD_ID" ]; then
        print_error "কিবোর্ড খুঁজে পাওয়া যায়নি! নাম কি পরিবর্তন হয়েছে?"
    fi

    # বর্তমান স্ট্যাটাস চেক করা
    STATE=$(xinput list-props "$KBD_ID" | grep "Device Enabled" | awk '{print $4}')

    if [ "$STATE" -eq 1 ]; then
        xinput disable "$KBD_ID"
        print_success "X11: বিল্ট-ইন কিবোর্ড ডিজেবল করা হয়েছে।"
    else
        xinput enable "$KBD_ID"
        print_success "X11: বিল্ট-ইন কিবোর্ড আবার এনাবল করা হয়েছে।"
    fi

elif [ "$SESSION_TYPE" = "wayland" ]; then
    # ২. Wayland (Hyprland) এর জন্য লজিক
    
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        if ! command -v hyprctl &> /dev/null; then
            print_error "hyprctl কমান্ড পাওয়া যাচ্ছে না!"
        fi
        
        # Wayland-এ স্ট্যাটাস সেভ রাখার জন্য একটি টেম্পোরারি ফাইল ব্যবহার করা হলো
        STATE_FILE="/tmp/kbd_state_wayland"
        
        if [ ! -f "$STATE_FILE" ] || [ "$(cat "$STATE_FILE")" = "enabled" ]; then
            hyprctl keyword device:$KBD_NAME_WAYLAND:enabled false > /dev/null
            echo "disabled" > "$STATE_FILE"
            print_success "Wayland (Hyprland): বিল্ট-ইন কিবোর্ড ডিজেবল করা হয়েছে।"
        else
            hyprctl keyword device:$KBD_NAME_WAYLAND:enabled true > /dev/null
            echo "enabled" > "$STATE_FILE"
            print_success "Wayland (Hyprland): বিল্ট-ইন কিবোর্ড আবার এনাবল করা হয়েছে।"
        fi
    else
        print_error "এই স্ক্রিপ্টের Wayland অংশটি শুধুমাত্র Hyprland-এর জন্য কনফিগার করা। অন্য কম্পোজিটরে কাজ নাও করতে পারে।"
    fi
else
    print_error "সেশন টাইপ (X11 বা Wayland) সঠিকভাবে শনাক্ত করা যায়নি!"
fi
