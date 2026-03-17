#!/usr/bin/env bash
# Profile management for devbox.
#
# Profiles install language-specific tooling into a running container.
# Each profile is an idempotent shell script in tooling/profiles/.
# Variants are declared via structured comment headers in profile scripts:
#   # VARIANTS: ml, api
#   # VARIANT_ml: description of ml variant
#   # VARIANT_api: description of api variant
set -euo pipefail

# Validate a profile name. Only alphanumeric, hyphens, and underscores allowed.
_validate_profile_name() {
    local name="$1"
    if [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi
    ui_error "Invalid profile name: '$name' (only alphanumeric, hyphens, and underscores allowed)"
    return 1
}

# List available profile names.
profile_list() {
    local profile_dir="${DEVBOX_ROOT}/tooling/profiles"
    if [ ! -d "$profile_dir" ]; then
        return 0
    fi
    for f in "${profile_dir}"/*.sh; do
        [ -f "$f" ] && basename "$f" .sh
    done
}

# List variant names for a profile. Outputs one variant per line.
profile_variants() {
    local name="$1"
    local profile_file="${DEVBOX_ROOT}/tooling/profiles/${name}.sh"
    if [ ! -f "$profile_file" ]; then
        return 0
    fi
    local variants_line
    variants_line="$(grep '^# VARIANTS:' "$profile_file" 2>/dev/null)" || return 0
    # Strip prefix, split on commas, trim whitespace.
    echo "$variants_line" | sed 's/^# VARIANTS://' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

# Get the description for a specific variant of a profile.
profile_variant_desc() {
    local name="$1"
    local variant="$2"
    local profile_file="${DEVBOX_ROOT}/tooling/profiles/${name}.sh"
    if [ ! -f "$profile_file" ]; then
        return 0
    fi
    grep "^# VARIANT_${variant}:" "$profile_file" 2>/dev/null | sed "s/^# VARIANT_${variant}:[[:space:]]*//" || true
}

# List profiles with variant annotations (e.g., "python [ml, api]").
profile_list_detailed() {
    local profile_dir="${DEVBOX_ROOT}/tooling/profiles"
    if [ ! -d "$profile_dir" ]; then
        return 0
    fi
    for f in "${profile_dir}"/*.sh; do
        [ -f "$f" ] || continue
        local name
        name="$(basename "$f" .sh)"
        local variants
        variants="$(profile_variants "$name")"
        if [ -n "$variants" ]; then
            # Join variants with ", " for display.
            local variant_list
            variant_list="$(echo "$variants" | tr '\n' ',' | sed 's/,/, /g;s/, $//')"
            echo "${name} [${variant_list}]"
        else
            echo "$name"
        fi
    done
}

# Auto-detect profiles from project files in a directory.
profile_detect() {
    local project_dir="${1:-.}"
    local detected=()

    [ -f "${project_dir}/Cargo.toml" ] && detected+=("rust")
    if [ -f "${project_dir}/pyproject.toml" ] || [ -f "${project_dir}/setup.py" ] \
        || [ -f "${project_dir}/requirements.txt" ]; then
        detected+=("python")
    fi
    [ -f "${project_dir}/package.json" ] && detected+=("node")
    [ -f "${project_dir}/go.mod" ] && detected+=("go")

    if [ ${#detected[@]} -gt 0 ]; then
        printf '%s\n' "${detected[@]}"
    fi
}

# Interactive profile selection menu. Prints the selected profile name,
# optionally followed by a variant (e.g., "python ml").
profile_menu() {
    local profiles_detailed
    profiles_detailed="$(profile_list_detailed)"

    if [ -z "$profiles_detailed" ]; then
        ui_error "No profiles available."
        return 1
    fi

    ui_header "Available Profiles"
    local i=1
    local profile_array=()
    while IFS= read -r p; do
        echo "  ${i}) ${p}" >&2
        # Store just the profile name (strip variant annotation).
        profile_array+=("${p%% \[*}")
        i=$((i + 1))
    done <<<"$profiles_detailed"
    echo "" >&2

    local choice attempts=0
    while true; do
        echo -n "Select a profile (number): " >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#profile_array[@]}" ]; then
            break
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 3 ]; then
            ui_error "Too many invalid attempts."
            return 1
        fi
        ui_warn "Invalid selection: enter a number between 1 and ${#profile_array[@]}." >&2
    done

    local selected="${profile_array[$((choice - 1))]}"
    local variants
    variants="$(profile_variants "$selected")"
    if [ -n "$variants" ]; then
        echo "" >&2
        ui_info "Available variants for ${selected}:" >&2
        local vi=1
        local variant_array=()
        while IFS= read -r v; do
            local desc
            desc="$(profile_variant_desc "$selected" "$v")"
            echo "  ${vi}) ${v} — ${desc}" >&2
            variant_array+=("$v")
            vi=$((vi + 1))
        done <<<"$variants"
        echo "  ${vi}) none (base profile only)" >&2
        echo "" >&2
        local vchoice
        echo -n "Select a variant (number, or Enter for none): " >&2
        read -r vchoice
        if [[ "$vchoice" =~ ^[0-9]+$ ]] && [ "$vchoice" -ge 1 ] && [ "$vchoice" -lt "$vi" ]; then
            echo "${selected} ${variant_array[$((vchoice - 1))]}"
            return 0
        fi
    fi
    echo "$selected"
}
