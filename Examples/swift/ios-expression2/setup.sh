#!/bin/bash
# Fetch the three things the app needs into Sources/Model/.
# Usage:  BITHUMAN_API_SECRET=… ./setup.sh <AGENT_CODE>
set -euo pipefail
cd "$(dirname "$0")"
CODE="${1:-}"
[ -n "$CODE" ] || { echo "usage: BITHUMAN_API_SECRET=… $0 <AGENT_CODE>"; exit 2; }
[ -n "${BITHUMAN_API_SECRET:-}" ] || { echo "set BITHUMAN_API_SECRET"; exit 2; }
mkdir -p Sources/Model

# 1. your agent's per-identity avatar
echo "==> downloading $CODE.avatar"
curl -fL --progress-bar -H "api-secret: $BITHUMAN_API_SECRET" \
  "https://api.bithuman.ai/v1/agent/$CODE/model/download?model=expression-2" \
  -o Sources/Model/agent.avatar
ls -l Sources/Model/agent.avatar

# 2. the shared speech front-end the artifact does not carry
echo "==> installing the shared engine graphs"
bithuman engine install mac
rm -rf Sources/Model/shared_engine
cp -R "$HOME/.bithuman/engines/mac-1.0.0" Sources/Model/shared_engine

# 3. something for it to say — macOS makes this for you
echo "==> synthesising speech16k.wav"
say -o /tmp/ios-expression2.aiff \
  "Hello. I am a bit Human avatar, rendered on this phone, with no server in the loop."
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/ios-expression2.aiff Sources/Model/speech16k.wav
rm -f /tmp/ios-expression2.aiff

echo "==> Sources/Model is ready:"
du -sh Sources/Model/*
