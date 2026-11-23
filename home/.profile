# cargo env is sourced only if it exists (a failed "." aborts the POSIX-sh Xsession wrapper)
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
