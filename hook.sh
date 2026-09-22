#!/usr/bin/env bash

# hook.sh — Event hook for agent profile injection
# Runs on startup (scans all) and on pane.agent_detected (scans specific)

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

# Parse event payload if available
EVENT_JSON="${HERDR_PLUGIN_EVENT_JSON:-}"
TARGET_PANE=""
if [[ -n "$EVENT_JSON" ]]; then
    TARGET_PANE=$(jq -r '.pane_id // empty' <<< "$EVENT_JSON" 2>/dev/null || true)
fi

# Function to decode base64url JSON (used for JWT)
decode_jwt_payload() {
    local jwt="$1"
    # Extract the payload (second part of JWT) using pure bash
    local temp="${jwt#*.}"
    local payload="${temp%%.*}"
    
    # Add padding if needed
    local pad=$((${#payload} % 4))
    if [[ "$pad" -eq 2 ]]; then payload="${payload}=="; fi
    if [[ "$pad" -eq 3 ]]; then payload="${payload}="; fi
    
    # Decode across platforms
    if command -v base64 >/dev/null; then
        base64 -D <<< "$payload" 2>/dev/null || base64 -d <<< "$payload" 2>/dev/null || echo "{}"
    else
        echo "{}"
    fi
}

# Cache for resolved profiles to avoid redundant file I/O or CLI calls
declare -A PROFILE_CACHE

# Resolve profile for a specific agent type
resolve_profile() {
    local agent_type="$1"
    
    # Return cached value if it exists
    if [[ -n "${PROFILE_CACHE[$agent_type]:-}" ]]; then
        echo "${PROFILE_CACHE[$agent_type]}"
        return
    fi
    
    local label=""

    case "$agent_type" in
        "claude")
            if command -v claude >/dev/null 2>&1; then
                local auth_json
                auth_json=$(claude auth status 2>/dev/null || echo "{}")
                # Single jq invocation to extract both fields
                IFS=$'\t' read -r email sub <<< $(jq -r '[.email // "", .subscriptionType // ""] | @tsv' <<< "$auth_json" 2>/dev/null || echo -e "\t")
                
                if [[ -n "$email" ]] && [[ -n "$sub" ]]; then
                    label="claude ($sub) · $email"
                elif [[ -n "$email" ]]; then
                    label="claude · $email"
                fi
            fi
            ;;
        
        "codex")
            local auth_file="$HOME/.codex/auth.json"
            if [[ -f "$auth_file" ]]; then
                local id_token
                id_token=$(jq -r '.tokens.id_token // empty' "$auth_file" 2>/dev/null || true)
                if [[ -n "$id_token" ]]; then
                    local decoded
                    decoded=$(decode_jwt_payload "$id_token")
                    IFS=$'\t' read -r email plan <<< $(jq -r '[.email // "", ."https://api.openai.com/auth".chatgpt_plan_type // ""] | @tsv' <<< "$decoded" 2>/dev/null || echo -e "\t")
                    
                    if [[ -n "$email" ]] && [[ -n "$plan" ]]; then
                        label="codex ($plan) · $email"
                    elif [[ -n "$email" ]]; then
                        label="codex · $email"
                    fi
                fi
            fi
            ;;
            
        "grok")
            local auth_file="$HOME/.grok/auth.json"
            if [[ -f "$auth_file" ]]; then
                # Grok auth is keyed by an ID. We use to_entries to grab the first object directly instead of recursive descent
                IFS=$'\t' read -r email tier <<< $(jq -r 'to_entries | .[0].value | [.email // "", ((.tier // "") | tostring)] | @tsv' "$auth_file" 2>/dev/null || echo -e "\t")
                
                if [[ -n "$email" ]] && [[ -n "$tier" ]]; then
                    label="grok (tier $tier) · $email"
                elif [[ -n "$email" ]]; then
                    label="grok · $email"
                fi
            fi
            ;;
            
        "agy"|"antigravity")
            local auth_file="$HOME/.gemini/google_accounts.json"
            if [[ -f "$auth_file" ]]; then
                local email
                email=$(jq -r '.active // empty' "$auth_file" 2>/dev/null || true)
                if [[ -n "$email" ]]; then
                    label="agy · $email"
                fi
            fi
            ;;
            
        "opencode")
            local config_file="$HOME/.config/opencode/opencode.json"
            if [[ -f "$config_file" ]]; then
                local provider_name
                provider_name=$(jq -r '.provider | to_entries | .[0].value.name // empty' "$config_file" 2>/dev/null || true)
                if [[ -n "$provider_name" ]]; then
                    label="opencode · $provider_name"
                fi
            fi
            ;;
    esac

    PROFILE_CACHE["$agent_type"]="$label"
    echo "$label"
}

# Fetch all agents
AGENTS_JSON=$("$HERDR" agent list 2>/dev/null || echo "{}")

# Process agents
while IFS=$'\t' read -r pane_id agent_type; do
    # Skip empty lines
    [[ -z "$pane_id" ]] && continue

    # Skip if we're targeting a specific pane and this isn't it
    if [[ -n "$TARGET_PANE" ]] && [[ "$TARGET_PANE" != "$pane_id" ]]; then
        continue
    fi

    # Skip if agent_type is missing
    [[ -z "$agent_type" ]] && continue

    PROFILE_LABEL=$(resolve_profile "$agent_type")
    
    if [[ -n "$PROFILE_LABEL" ]]; then
        # Inject metadata
        "$HERDR" pane report-metadata "$pane_id" --source "agent-profiles" --token "provider=$PROFILE_LABEL" 2>/dev/null || true
    fi
done < <(jq -r '(.result.agents // [])[] | [.pane_id, .agent] | @tsv' <<< "$AGENTS_JSON" 2>/dev/null || true)
