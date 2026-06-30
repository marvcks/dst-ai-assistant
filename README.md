# DST AI Assistant

An in-game AI assistant for Don't Starve Together dedicated servers. Players ask questions in normal chat with `@ai`, and the answer is announced in game. The assistant receives a fresh read-only snapshot of the world and the active player, including season/day, vitals, inventory, nearby base structures, living bosses, and the next hound attack.

The project is independent of any server WebUI. It contains:

- `mod/`: the multiplayer DST mod;
- `service/`: a small localhost-only Python service that calls an OpenAI-compatible API;
- `scripts/install.sh`: dedicated-server installer.

## Why a companion service is required

DST's standard mod configuration screen only supports predefined dropdown values, so it cannot accept an arbitrary URL or secret. The Lua HTTP API also cannot attach the `Authorization` header required by OpenAI-compatible providers. The companion service solves both constraints while keeping the API key in a mode-0600 file on the dedicated server.

The service binds to `127.0.0.1`; it does not expose the configuration endpoint to the internet and never returns the stored key. The Mod only handles read-only game state, the admin configuration screen, and in-game announcements.

## Install on a dedicated server

Requirements: Linux, systemd, Python 3.10+, and a normal DST dedicated-server installation.

```bash
git clone https://github.com/marvcks/dst-ai-assistant.git
cd dst-ai-assistant
sudo DST_ROOT=/opt/dst-server CLUSTER_NAME=MyDediServer ./scripts/install.sh
sudo systemctl restart dst-server
```

If the server is managed by Docker Compose, restart it with the command used by that deployment instead of `systemctl restart dst-server`.

The installer:

1. copies the Mod to `server/mods/dst_ai_assistant`;
2. enables it in the selected cluster's `modoverrides.lua`;
3. installs a locked-down `dst-ai-assistant.service` bound to localhost;
4. creates `/var/lib/dst-ai-assistant/config.json` with permission `0600` when configuration is first saved.

The service unit assumes the usual single-Master layout. Edit the unit if your logs or Mod directory are elsewhere.

## Configure in game

The assistant works server-side, so ordinary players do not have to install the Mod. The administrator who wants the in-game configuration screen must also place `mod/` in their local DST `mods/dst_ai_assistant` folder and enable it.

1. Join as a server administrator.
2. Enter `/aiconfig` in chat.
3. Set the OpenAI-compatible base URL, model name, and API key.
4. Save, then ask `@ai 现在是什么季节？` in normal chat.

Examples:

| Provider | Base URL | Typical model |
| --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat` |
| OpenAI | `https://api.openai.com/v1` | provider-supported chat model |
| Local gateway | `http://127.0.0.1:8000/v1` | gateway model name |

Leaving the API-key field blank preserves the existing key. The key is masked in the UI and is never sent back to a client.

## Manual configuration fallback

If `TheSim:QueryServer` is disabled by a future DST security update, stop the service and create `/var/lib/dst-ai-assistant/config.json` manually:

```json
{
  "base_url": "https://api.deepseek.com",
  "model": "deepseek-chat",
  "api_key": "replace-me"
}
```

Set ownership to `dst-ai:dst-ai`, mode `0600`, then restart `dst-ai-assistant.service`.

## Operations

```bash
curl http://127.0.0.1:8765/health
sudo systemctl status dst-ai-assistant
sudo journalctl -u dst-ai-assistant -f
python3 -m unittest discover -s tests -v
```

The Mod is fail-soft: a missing companion service or malformed response does not execute arbitrary Lua and does not stop the DST world. Requests are rate-limited per player, limited to 500 characters, and LLM replies are stripped of Markdown before display.

## Publishing to Steam Workshop

Upload the contents of `mod/` as the Workshop item. After Steam assigns an item ID, replace the local Mod key in `modoverrides.lua` with `workshop-<ID>` and add `ServerModSetup("<ID>")` to `dedicated_server_mods_setup.lua`. Keep the companion service installed on the host.

Build a client/Workshop-ready archive with:

```bash
./scripts/package.sh
```

## License

MIT
