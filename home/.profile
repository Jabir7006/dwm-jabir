# Graphical launchers inherit this PATH from LightDM, not from an interactive shell.
for dwm_user_bin in "$HOME/custom-scripts" "$HOME/.local/bin"; do
    case ":${PATH:-}:" in
        *:"$dwm_user_bin":*) ;;
        *) PATH="$dwm_user_bin${PATH:+:$PATH}" ;;
    esac
done
unset dwm_user_bin
export PATH
if [ -r "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
