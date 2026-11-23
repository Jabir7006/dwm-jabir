# secrets (API token/key) — never committed
test -f "$HOME/.config/dwm-titus/secrets.fish"; and source "$HOME/.config/dwm-titus/secrets.fish"

if status is-interactive
    # Replace default fish greeting with fastfetch
    function fish_greeting
        if command -q fastfetch
            if test -r "$HOME/.config/fastfetch/config.jsonc"
                fastfetch --config "$HOME/.config/fastfetch/config.jsonc"
            else
                fastfetch
            end
        end
    end

    # Starship custom prompt
    if command -q starship
        starship init fish | source
    end

    # Direnv + Zoxide
    command -v direnv &> /dev/null && direnv hook fish | source
    command -v zoxide &> /dev/null && zoxide init fish --cmd cd | source

    # Better ls
    alias ls='eza --icons --group-directories-first -1'

    # Abbrs
    abbr lg 'lazygit'
    abbr gd 'git diff'
    abbr ga 'git add .'
    abbr gc 'git commit -am'
    abbr gl 'git log'
    abbr gs 'git status'
    abbr gst 'git stash'
    abbr gsp 'git stash pop'
    abbr gp 'git push'
    abbr gpl 'git pull'
    abbr gsw 'git switch'
    abbr gsm 'git switch main'
    abbr gb 'git branch'
    abbr gbd 'git branch -d'
    abbr gco 'git checkout'
    abbr gsh 'git show'

    abbr l 'ls'
    abbr ll 'ls -l'
    abbr la 'ls -a'
    abbr lla 'ls -la'
    
    abbr ff 'fastfetch'
    abbr cls 'clear'

    abbr i 'sudo pacman -S'
    abbr u 'sudo pacman -Syu'
    alias r='~/custom-scripts/uninstaller.sh'
    # 'r' কমান্ডের পর ট্যাব চাপলে সিস্টেমে ইন্সটলড (pacman -Qq) সব প্যাকেজ সাজেস্ট করবে
    complete -c r -f -a "(pacman -Qq)"

    abbr y 'yay -S'
    abbr yu 'yay -Syu'
    abbr purge 'sudo pacman -Rnsc'    
    abbr ys 'yay -Ss'
    
    # Custom colours
    cat ~/.local/state/caelestia/sequences.txt 2> /dev/null

    # For jumping between prompts in foot terminal
    function mark_prompt_start --on-event fish_prompt
        echo -en "\e]133;A\e\\"
    end

    # Custom interactive search & install function
    function s
        if test (count $argv) -eq 0
            echo "Please provide a search term."
            return 1
        end
        
        # সরাসরি yay রান করলে সে সার্চ করবে এবং নাম্বার দিয়ে ইন্সটল করার প্রম্পট দেবে
        yay $argv
    end
    
    function gcm --description "Generate professional conventional commit message from staged changes"
    # Check if there are staged changes
    if not git diff --cached --quiet
        set -l prompt "Analyze the following staged git changes and generate a single professional conventional commit message.

Rules:
- Follow Conventional Commits specification strictly (feat, fix, refactor, docs, style, test, chore, perf, ci, build, revert)
- Format: <type>(optional-scope): <description>
- Description must be imperative mood, lowercase, no period at the end
- Keep it concise (max 72 characters for the subject line)
- If body is needed, separate with a blank line
- Output ONLY the commit message. No quotes, no explanation, no markdown, no extra text."

        git diff --cached | opencode run $prompt
    else
        echo "No staged changes found." >&2
        return 1
    end
end

    set -gx EDITOR nano
    set -gx VISUAL l3afpad
    # fnm is initialized once by conf.d/fnm.fish, when it is installed.
    command -v thefuck &> /dev/null && thefuck --alias | source
end
# pnpm
set -gx PNPM_HOME "$HOME/.local/share/pnpm"
if not string match -q -- "$PNPM_HOME/bin" $PATH
  set -gx PATH "$PNPM_HOME/bin" $PATH
end
# pnpm end

set -g fish_ambiguous_width 1

# Codex (AgentRouter) API key — install.sh runs: setup-secrets.sh
set -gx AGENT_ROUTER_TOKEN "$AGENT_ROUTER_TOKEN"
