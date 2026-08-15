#!/usr/bin/env bash
#
# install.sh - deploy these dotfiles onto a fresh macOS or Linux machine.
#
#   ./install.sh                  # symlink everything for this OS (backs up what it replaces)
#   ./install.sh --dry-run        # show what would happen, touch nothing
#   ./install.sh --copy           # copy files instead of symlinking
#   ./install.sh --only zsh,tmux  # install just those modules
#   ./install.sh --list           # list module names
#   ./install.sh --skip zotero    # install everything except those
#   ./install.sh --packages       # also install the CLI tools the configs expect
#   ./install.sh --cursor-extensions   # also reinstall the Cursor extensions
#
# Run it from anywhere; it resolves paths relative to the repo.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=link          # link | copy
DRY_RUN=0
DO_PACKAGES=0
DO_CURSOR_EXT=0
ONLY=""
SKIP=""
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

# All modules, in install order. Format: name:platform (any|macos|linux)
MODULES="
zsh:any
shell:any
bash:any
zprofile:macos
nvim:any
tmux:any
alacritty:any
lf:any
htop:any
mpv:any
yabai:macos
claude:any
cursor:any
zotero:any
"

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
warn()  { printf '%s warn:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '%s error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
note()  { printf '%s  %s%s\n' "$DIM" "$*" "$RESET"; }

# Print a path with $HOME collapsed to ~, for readable logs.
tilde() { printf '%s' "${1/#$HOME/\~}"; }

have() { command -v "$1" >/dev/null 2>&1; }

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s  would: %s%s\n' "$DIM" "$*" "$RESET"
    else
        "$@"
    fi
}

# ----------------------------------------------------------------- usage ----

# Print the comment header at the top of this file, minus the shebang.
usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
}

list_modules() {
    for entry in $MODULES; do
        name="${entry%%:*}"; platform="${entry##*:}"
        if [ "$platform" = any ]; then
            printf '  %-10s\n' "$name"
        else
            printf '  %-10s %s(%s only)%s\n' "$name" "$DIM" "$platform" "$RESET"
        fi
    done
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n)  DRY_RUN=1 ;;
        --copy)        MODE=copy ;;
        --link)        MODE=link ;;
        --packages)    DO_PACKAGES=1 ;;
        --cursor-extensions) DO_CURSOR_EXT=1 ;;
        --only)        ONLY="${2:-}"; shift ;;
        --only=*)      ONLY="${1#*=}" ;;
        --skip)        SKIP="${2:-}"; shift ;;
        --skip=*)      SKIP="${1#*=}" ;;
        --list|-l)     list_modules ;;
        --help|-h)     usage ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# CSV membership test: in_csv <needle> <csv>
in_csv() {
    case ",${2}," in *",${1},"*) return 0 ;; *) return 1 ;; esac
}

wanted() {
    [ -n "$ONLY" ] && { in_csv "$1" "$ONLY" || return 1; }
    [ -n "$SKIP" ] && { in_csv "$1" "$SKIP" && return 1; }
    return 0
}

# --------------------------------------------------------------- linking ----

# Move an existing destination out of the way, into the timestamped backup dir.
backup() {
    local dest="$1" rel
    [ -e "$dest" ] || [ -L "$dest" ] || return 0
    # Mirror the path under the backup dir so names never collide.
    rel="${dest#"$HOME"/}"
    note "backup   $(tilde "$dest")"
    run mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    run mv "$dest" "$BACKUP_DIR/$rel"
}

# install <src-relative-to-repo> <absolute-dest>
install_path() {
    local src="$REPO/$1" dest="$2"

    [ -e "$src" ] || { warn "missing in repo: $1"; return 0; }

    # Already pointing where we want it? Nothing to do.
    if [ "$MODE" = link ] && [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
        note "ok       $(tilde "$dest")"
        return 0
    fi

    backup "$dest"
    run mkdir -p "$(dirname "$dest")"

    if [ "$MODE" = link ]; then
        note "link     $(tilde "$dest") -> $1"
        run ln -sfn "$src" "$dest"
    else
        note "copy     $(tilde "$dest") <- $1"
        if [ -d "$src" ]; then
            run cp -R "$src" "$dest"
        else
            run cp "$src" "$dest"
        fi
    fi
}

# Append a line to a file unless it is already there.
ensure_line() {
    local line="$1" file="$2"
    if [ -f "$file" ] && grep -Fqx "$line" "$file"; then
        note "ok       $(tilde "$file") already has: $line"
        return 0
    fi
    note "append   $(tilde "$file"): $line"
    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "$file")"
        printf '%s\n' "$line" >> "$file"
    fi
}

XDG="${XDG_CONFIG_HOME:-$HOME/.config}"

# --------------------------------------------------------------- modules ----

module_zsh() {
    local plugin name

    install_path zsh/.zshrc   "$XDG/zsh/.zshrc"
    install_path zsh/.p10k.zsh "$XDG/zsh/.p10k.zsh"

    # Link each plugin individually so the plugins dir stays a real directory
    # and extra clones (see below) don't end up inside the repo.
    run mkdir -p "$XDG/zsh/plugins"
    for plugin in "$REPO"/zsh/plugins/*/; do
        [ -d "$plugin" ] || continue
        name="$(basename "$plugin")"
        # Empty placeholder dirs in the repo: install them from upstream instead.
        if [ -z "$(ls -A "$plugin")" ]; then
            clone_plugin "$name"
            continue
        fi
        install_path "zsh/plugins/$name" "$XDG/zsh/plugins/$name"
    done

    # .zshrc lives under ~/.config/zsh, so zsh needs ZDOTDIR to find it.
    ensure_line 'export ZDOTDIR="$HOME/.config/zsh"' "$HOME/.zshenv"

    # HISTFILE=~/.cache/zsh/history — zsh won't create the directory itself.
    run mkdir -p "$HOME/.cache/zsh"
}

clone_plugin() {
    local name="$1" url="" dest="$XDG/zsh/plugins/$1"
    case "$name" in
        zsh-autosuggestions) url=https://github.com/zsh-users/zsh-autosuggestions ;;
        *) warn "empty plugin dir with no known source: $name"; return 0 ;;
    esac
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        note "ok       $(tilde "$dest") (already present)"
        return 0
    fi
    backup "$dest"
    note "clone    $url -> $(tilde "$dest")"
    if have git; then
        run git clone --depth 1 "$url" "$dest"
    else
        warn "git not found, skipping $name"
    fi
}

module_shell() {
    install_path aliasrc    "$XDG/aliasrc"
    install_path shortcutrc "$XDG/shortcutrc"
}

module_bash()     { install_path .bashrc  "$HOME/.bashrc"; }
module_zprofile() { install_path .zprofile "$HOME/.zprofile"; }

module_nvim() {
    install_path nvim/init.vim          "$XDG/nvim/init.vim"
    install_path nvim/autoload/plug.vim "$XDG/nvim/autoload/plug.vim"
    # Plugins are not vendored - vim-plug fetches them into ~/.config/nvim/plugged.
    note "run :PlugInstall inside nvim to fetch plugins"
}

module_tmux() {
    install_path tmux/tmux.conf "$XDG/tmux/tmux.conf"

    # tmux < 3.1 only looks at ~/.tmux.conf.
    if [ -L "$HOME/.tmux.conf" ] && [ "$(readlink "$HOME/.tmux.conf")" = "$XDG/tmux/tmux.conf" ]; then
        note "ok       ~/.tmux.conf"
    else
        backup "$HOME/.tmux.conf"
        note "link     ~/.tmux.conf -> $(tilde "$XDG/tmux/tmux.conf")"
        run ln -sfn "$XDG/tmux/tmux.conf" "$HOME/.tmux.conf"
    fi

    # The clipboard bindings call pbcopy/pbpaste. On Linux, override them
    # through the ~/.tmux_local.conf hook tmux.conf already sources.
    if [ "$OS" = linux ] && [ ! -e "$HOME/.tmux_local.conf" ]; then
        local copy paste
        if [ -n "${WAYLAND_DISPLAY:-}" ] && have wl-copy; then
            copy="wl-copy"; paste="wl-paste --no-newline"
        elif have xclip; then
            copy="xclip -selection clipboard -in"; paste="xclip -selection clipboard -out"
        elif have xsel; then
            copy="xsel --clipboard --input"; paste="xsel --clipboard --output"
        else
            warn "no clipboard tool found (install wl-clipboard, xclip or xsel) - tmux copy will not reach the system clipboard"
            return 0
        fi
        note "write    ~/.tmux_local.conf (clipboard via ${copy%% *})"
        if [ "$DRY_RUN" = 0 ]; then
            cat > "$HOME/.tmux_local.conf" <<EOF
# Generated by install.sh: Linux clipboard equivalents of the pbcopy bindings.
bind -T copy-mode-vi "y"   send -X copy-pipe-and-cancel "$copy"
bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel "$copy"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-no-clear "$copy"
bind -n DoubleClick1Pane select-pane \; copy-mode -M \; send -X select-word \; send -X copy-pipe-and-cancel "$copy"
bind -n TripleClick1Pane select-pane \; copy-mode -M \; send -X select-line \; send -X copy-pipe-and-cancel "$copy"
bind -n MouseDown2Pane run 'tmux set-buffer -b p "\$($paste)"; tmux paste-buffer -p -d -b p'
EOF
        fi
    fi
}

module_alacritty() { install_path alacritty/alacritty.yml "$XDG/alacritty/alacritty.yml"; }

module_lf() {
    install_path lf/lfrc  "$XDG/lf/lfrc"
    install_path lf/scope "$XDG/lf/scope"
    [ "$DRY_RUN" = 0 ] && chmod +x "$XDG/lf/scope"
    return 0
}

module_htop() { install_path htop/htoprc "$XDG/htop/htoprc"; }

module_mpv() {
    install_path mpv/mpv.conf     "$XDG/mpv/mpv.conf"
    install_path mpv/input.conf   "$XDG/mpv/input.conf"
    install_path mpv/scripts      "$XDG/mpv/scripts"
    install_path mpv/lua-settings "$XDG/mpv/lua-settings"
}

module_yabai() {
    install_path yabai/yabairc "$XDG/yabai/yabairc"
    [ "$DRY_RUN" = 0 ] && chmod +x "$XDG/yabai/yabairc"
    return 0
}

module_claude() { install_path claude/settings.json "$HOME/.claude/settings.json"; }

module_cursor() {
    local user_dir
    if [ "$OS" = macos ]; then
        user_dir="$HOME/Library/Application Support/Cursor/User"
    else
        user_dir="$XDG/Cursor/User"
    fi
    install_path cursor/settings.json    "$user_dir/settings.json"
    install_path cursor/keybindings.json "$user_dir/keybindings.json"

    # Extensions are slow to install (42 of them), so they are opt-in.
    if [ "$DO_CURSOR_EXT" = 1 ]; then
        have cursor || die "'cursor' CLI not on PATH (Cursor: Cmd-Shift-P > Install 'cursor' command)"
        note "installing extensions from cursor/extensions.txt"
        if [ "$DRY_RUN" = 0 ]; then
            xargs -n1 cursor --install-extension < "$REPO/cursor/extensions.txt" || \
                warn "some extensions failed to install"
        fi
    else
        note "extensions: rerun with --cursor-extensions (or: xargs -n1 cursor --install-extension < cursor/extensions.txt)"
    fi
}

module_zotero() {
    install_path zotero/styles/nature.csl "$HOME/Zotero/styles/nature.csl"
    note "prefs are not applied automatically - see README (Zotero)"
}

# ---------------------------------------------------------------- extras ----

PACKAGES="git zsh tmux neovim fzf htop ripgrep bat lf"

install_packages() {
    step "Packages"
    if [ "$OS" = macos ]; then
        have brew || die "Homebrew not installed - see https://brew.sh"
        run brew install $PACKAGES eza
    elif have apt-get; then
        run sudo apt-get update
        # exa/eza naming differs by release; try eza, fall back to exa.
        run sudo apt-get install -y $PACKAGES xclip
        run sudo apt-get install -y eza || run sudo apt-get install -y exa || \
            warn "neither eza nor exa available - the ls alias will not work"
    elif have dnf; then
        run sudo dnf install -y $PACKAGES eza xclip
    elif have pacman; then
        run sudo pacman -S --needed --noconfirm $PACKAGES eza xclip
    else
        warn "no supported package manager found; install manually: $PACKAGES eza"
    fi
}

# ------------------------------------------------------------------ main ----

step "Dotfiles from $(tilde "$REPO") ($OS, mode=$MODE)"

if [ "$DRY_RUN" = 1 ]; then info "${DIM}dry run - nothing will be written${RESET}"; fi

if [ "$DO_PACKAGES" = 1 ]; then install_packages; fi

installed=""
for entry in $MODULES; do
    name="${entry%%:*}"; platform="${entry##*:}"

    wanted "$name" || continue
    if [ "$platform" != any ] && [ "$platform" != "$OS" ]; then
        note "skip     $name ($platform only)"
        continue
    fi

    step "$name"
    "module_$name"
    installed="$installed $name"
done

if [ -n "$ONLY" ]; then
    for name in ${ONLY//,/ }; do
        case " $installed " in
            *" $name "*) ;;
            *) warn "no such module (or not for this OS): $name" ;;
        esac
    done
fi

step "Done"
if [ "$DRY_RUN" = 0 ] && [ -d "$BACKUP_DIR" ]; then
    info "Replaced files were backed up to $(tilde "$BACKUP_DIR")"
fi
info "Next steps:"
info "  - restart your shell (or: exec zsh)"
info "  - nvim +PlugInstall +qall   to fetch neovim plugins"
if [ "$OS" = macos ]; then
    info "  - bash .macos               to apply macOS defaults (optional, changes a lot of system settings)"
fi
info "  - chsh -s \"\$(command -v zsh)\"  if zsh is not your login shell"
