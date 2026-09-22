#!/usr/bin/env bash

# hook.sh — Event hook for agent profile injection
# Runs on startup (scans all) and on pane.agent_detected (scans specific)

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"

# Parse event payload if available
EVENT_JSON="${HERDR_PLUGIN_EVENT_JSON:-}"
TARGET_PANE=""
if [ -n "$EVENT_JSON" ]; then
    TARGET_PANE=$(echo "$EVENT_JSON" | jq -r '.pane_id // empty' 2>/dev/null || true)
fi

# Function to decode base64url JSON (used for JWT)
decode_jwt_payload() {
    local jwt="$1"
    local payload=$(echo "$jwt" | cut -d'.' -f2)
    # Add padding if needed
    local pad=$((${#payload} % 4))
    if [ "$pad" -eq 2 ]; then payload="${payload}=="; fi
    if [ "$pad" -eq 3 ]; then payload="${payload}="; fi
    echo "$payload" | base64 -D 2>/dev/null || base64 -d 2>/dev/null || echo "{}"
}

# Resolve profile for a specific agent type
resolve_profile() {
    local agent_type="$1"
    local label=""

    case "$agent_type" in
        "claude")
            # Uses CLI directly as it's the most reliable for Claude
            if command -v claude >/dev/null 2>&1; then
                local auth_json=$(claude auth status 2>/dev/null || echo "{}")
                local email=$(echo "$auth_json" | jq -r '.email // empty' 2>/dev/null)
                local sub=$(echo "$auth_json" | jq -r '.subscriptionType // empty' 2>/dev/null)
                
                if [ -n "$email" ] && [ -n "$sub" ]; then
                    label="claude ($sub) · $email"
                elif [ -n "$email" ]; then
                    label="claude · $email"
                fi
            fi
            ;;
        
        "codex")
            local auth_file="$HOME/.codex/auth.json"
            if [ -f "$auth_file" ]; then
                local id_token=$(jq -r '.tokens.id_token // empty' "$auth_file" 2>/dev/null)
                if [ -n "$id_token" ]; then
                    local decoded=$(decode_jwt_payload "$id_token")
                    local email=$(echo "$decoded" | jq -r '.email // empty' 2>/dev/null)
                    local plan=$(echo "$decoded" | jq -r '."https://api.openai.com/auth".chatgpt_plan_type // empty' 2>/dev/null)
                    
                    if [ -n "$email" ] && [ -n "$plan" ]; then
                        label="codex ($plan) · $email"
                    elif [ -n "$email" ]; then
                        label="codex · $email"
                    fi
                fi
            fi
            ;;
            
        "grok")
            local auth_file="$HOME/.grok/auth.json"
            if [ -f "$auth_file" ]; then
                # Grok auth is keyed by an ID, we just grab the first values we find
                local email=$(jq -r '.. | .email? | select(type == "string")' "$auth_file" 2>/dev/null | head -n 1)
                local tier=$(jq -r '.. | .tier? | select(type == "number")' "$auth_file" 2>/dev/null | head -n 1)
                
                if [ -n "$email" ] && [ -n "$tier" ]; then
                    label="grok (tier $tier) · $email"
                elif [ -n "$email" ]; then
                    label="grok · $email"
                fi
            fi
            ;;
            
        "agy"|"antigravity")
            local auth_file="$HOME/.gemini/google_accounts.json"
            if [ -f "$auth_file" ]; then
                local email=$(jq -r '.active // empty' "$auth_file" 2>/dev/null)
                if [ -n "$email" ]; then
                    label="agy · $email"
                fi
            fi
            ;;
            
        "opencode")
            local config_file="$HOME/.config/opencode/opencode.json"
            if [ -f "$config_file" ]; then
                # Grab the first configured provider name
                local provider_name=$(jq -r '.provider | to_entries | .[0].value.name // empty' "$config_file" 2>/dev/null)
                if [ -n "$provider_name" ]; then
                    label="opencode · $provider_name"
                fi
            fi
            ;;
    esac

    echo "$label"
}

# Fetch all agents
AGENTS_JSON=$("$HERDR" agent list 2>/dev/null || echo "{}")

# Process agents
jq -r '(.result.agents // [])[] | [.pane_id, .agent] | @tsv' <<< "$AGENTS_JSON" | while IFS=$'\t' read -r pane_id agent_type; do
    # Skip if we're targeting a specific pane and this isn't it
    if [ -n "$TARGET_PANE" ] && [ "$TARGET_PANE" != "$pane_id" ]; then
        continue
    fi

    # Skip if agent_type is missing
    [ -z "$agent_type" ] && continue

    PROFILE_LABEL=$(resolve_profile "$agent_type")
    
    if [ -n "$PROFILE_LABEL" ]; then
        # Inject metadata
        "$HERDR" pane report-metadata "$pane_id" --source "agent-profiles" --token "provider=$PROFILE_LABEL" 2>/dev/null || true
    fi
done
