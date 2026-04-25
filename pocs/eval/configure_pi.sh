#!/usr/bin/env bash
# Usage: configure_pi.sh <provider_name> <base_url> <api_key> <model_id>
#
# Rewrites ~/.pi/agent/models.json so pi targets the given OpenAI-compat
# endpoint as a custom provider.
set -euo pipefail
PROVIDER="${1:?provider name}"
BASE_URL="${2:?base url}"
API_KEY="${3:?api key}"
MODEL_ID="${4:?model id}"

mkdir -p "$HOME/.pi/agent"
python3 <<PY
import json, pathlib
p = pathlib.Path.home() / ".pi" / "agent"
models = p / "models.json"
settings = p / "settings.json"

cfg = {
    "providers": {
        "$PROVIDER": {
            "baseUrl": "$BASE_URL",
            "api": "openai-completions",
            "apiKey": "$API_KEY",
            "authHeader": True,
            "models": [{
                "id": "$MODEL_ID",
                "name": "$MODEL_ID",
                "reasoning": False,
                "input": ["text"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 32768,
                "maxTokens": 32768,
            }],
        }
    }
}
models.write_text(json.dumps(cfg, indent=2))
settings.write_text(json.dumps({"defaultProvider": "$PROVIDER", "defaultModel": "$MODEL_ID"}, indent=2))
print(f"pi configured: provider=$PROVIDER baseUrl=$BASE_URL model=$MODEL_ID")
PY
