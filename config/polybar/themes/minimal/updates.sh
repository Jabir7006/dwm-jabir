#!/usr/bin/env bash

# নোটিফিকেশন দেখানোর জন্য
if [ "$1" == "--notify" ]; then
    official=$(checkupdates 2>/dev/null | wc -l)
    aur=$(yay -Qua 2>/dev/null | wc -l)
    
    # যদি কোনো এরর থাকে তবে 0 দেখাবে
    official=${official:-0}
    aur=${aur:-0}
    
    notify-send -u normal "📦 System Updates" "Official (Pacman): $official\nAUR (Yay): $aur"
else
    # পলিবারের ওপর আইকন এবং মোট আপডেটের সংখ্যা দেখানোর জন্য
    official=$(checkupdates 2>/dev/null | wc -l)
    aur=$(yay -Qua 2>/dev/null | wc -l)
    
    official=${official:-0}
    aur=${aur:-0}
    
    total=$((official + aur))
    
    #  এর জায়গায় আপনি যেকোনো আইকন ব্যবহার করতে পারেন
    echo " $total"
fi
