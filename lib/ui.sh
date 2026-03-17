#!/usr/bin/env bash
# TUI helpers for devbox CLI output.
#
# Provides consistent formatting for info, warnings, errors, and headers.
set -euo pipefail

# Colors (only if terminal supports them and NO_COLOR is not set).
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ] && command -v tput &>/dev/null; then
    _BOLD="$(tput bold)"
    _RED="$(tput setaf 1)"
    _YELLOW="$(tput setaf 3)"
    _GREEN="$(tput setaf 2)"
    _CYAN="$(tput setaf 6)"
    _RESET="$(tput sgr0)"
else
    _BOLD=""
    _RED=""
    _YELLOW=""
    _GREEN=""
    _CYAN=""
    _RESET=""
fi

ui_header() {
    [ "${DEVBOX_QUIET:-}" = "1" ] && return 0
    echo ""
    echo "${_BOLD}${_CYAN}=== $* ===${_RESET}"
    echo ""
}

ui_info() {
    [ "${DEVBOX_QUIET:-}" = "1" ] && return 0
    echo "${_GREEN}[info]${_RESET} $*"
}

ui_warn() {
    echo "${_YELLOW}[warn]${_RESET} $*" >&2
}

ui_error() {
    echo "${_RED}[error]${_RESET} $*" >&2
}

# Display a spinner with a message while waiting.
# Usage: ui_spinner "message" & local pid=$!; ...; kill $pid 2>/dev/null
ui_spinner() {
    [ "${DEVBOX_QUIET:-}" = "1" ] && return 0
    local msg="${1:-Waiting...}"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while true; do
        printf "\r${_CYAN}%s${_RESET} %s " "${chars:i%10:1}" "$msg"
        i=$((i + 1))
        sleep 0.2
    done
}

# Prompt the user for confirmation. Returns 0 for yes, 1 for no.
# Optional second param: default ("y" or "n", default "n").
# Retries on invalid input up to 3 times before applying the default.
ui_confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"
    local hint="[y/N]"
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    fi
    local attempts=0
    while [ "$attempts" -lt 3 ]; do
        local response
        echo -n "${_BOLD}${prompt} ${hint}${_RESET} "
        read -r response
        case "$response" in
            [yY] | [yY][eE][sS]) return 0 ;;
            [nN] | [nN][oO]) return 1 ;;
            "")
                if [[ "$default" == "y" ]]; then
                    return 0
                fi
                return 1
                ;;
            *)
                attempts=$((attempts + 1))
                if [ "$attempts" -lt 3 ]; then
                    echo "  Please answer y or n."
                fi
                ;;
        esac
    done
    # Exhausted retries — apply default.
    if [[ "$default" == "y" ]]; then
        return 0
    fi
    return 1
}
