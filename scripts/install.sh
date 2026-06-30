#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this installer as root (for example: sudo ./scripts/install.sh)." >&2
    exit 1
fi

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DST_ROOT=${DST_ROOT:-/opt/dst-server}
CLUSTER_NAME=${CLUSTER_NAME:-MyDediServer}
MOD_DIR="$DST_ROOT/server/mods/dst_ai_assistant"
MASTER_DIR="$DST_ROOT/DoNotStarveTogether/$CLUSTER_NAME/Master"
SERVICE_DIR=/opt/dst-ai-assistant
DATA_DIR=/var/lib/dst-ai-assistant
SERVICE_USER=dst-ai

for required in "$DST_ROOT/server/mods" "$MASTER_DIR"; do
    if [[ ! -d "$required" ]]; then
        echo "Required DST directory not found: $required" >&2
        exit 1
    fi
done

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
DST_GROUP=$(stat -c '%G' "$DST_ROOT")
if getent group "$DST_GROUP" >/dev/null 2>&1; then
    usermod -a -G "$DST_GROUP" "$SERVICE_USER"
fi

install -d -m 0755 "$SERVICE_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$DATA_DIR"
install -d -o root -g "$SERVICE_USER" -m 0775 "$MOD_DIR"
install -d -o root -g "$SERVICE_USER" -m 0755 "$MOD_DIR/scripts"
install -d -o root -g "$SERVICE_USER" -m 0755 "$MOD_DIR/scripts/screens"
install -m 0644 "$PROJECT_ROOT/mod/modinfo.lua" "$MOD_DIR/modinfo.lua"
install -m 0644 "$PROJECT_ROOT/mod/modmain.lua" "$MOD_DIR/modmain.lua"
install -m 0644 "$PROJECT_ROOT/mod/scripts/dst_ai_state.lua" "$MOD_DIR/scripts/dst_ai_state.lua"
install -m 0644 "$PROJECT_ROOT/mod/scripts/screens/dst_ai_config_screen.lua" "$MOD_DIR/scripts/screens/dst_ai_config_screen.lua"
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 "$PROJECT_ROOT/mod/response.lua" "$MOD_DIR/response.lua"
install -m 0755 "$PROJECT_ROOT/service/dst_ai_service.py" "$SERVICE_DIR/dst_ai_service.py"

UNIT=/etc/systemd/system/dst-ai-assistant.service
sed \
    -e "s|/opt/dst-server/DoNotStarveTogether/MyDediServer/Master|$MASTER_DIR|g" \
    -e "s|/opt/dst-server/server/mods/dst_ai_assistant|$MOD_DIR|g" \
    "$PROJECT_ROOT/service/dst-ai-assistant.service" > "$UNIT"
chmod 0644 "$UNIT"

OVERRIDES="$MASTER_DIR/modoverrides.lua"
if [[ -f "$OVERRIDES" ]] && ! grep -q '\["dst_ai_assistant"\]' "$OVERRIDES"; then
    cp -a "$OVERRIDES" "$OVERRIDES.pre-dst-ai-assistant-$(date +%Y%m%d-%H%M%S)"
    python3 - "$OVERRIDES" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
position = text.rfind("}")
if position < 0:
    raise SystemExit("modoverrides.lua has no closing table brace")
entry = '    ["dst_ai_assistant"] = { enabled = true },\n'
path.write_text(text[:position] + entry + text[position:], encoding="utf-8")
PY
fi

systemctl daemon-reload
systemctl enable --now dst-ai-assistant.service

echo "Installed DST AI Assistant."
echo "Restart the DST world, then install/enable the same mod on an admin client and run /aiconfig."
