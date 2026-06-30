name = "DST AI Assistant"
description = [[
Ask an AI about the current world with "@ai your question".
Server admins can configure the LLM in game with "/aiconfig".
Requires the bundled localhost companion service on the server.
]]
author = "marvcks"
version = "1.0.0"

api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

client_only_mod = false
server_only_mod = false
all_clients_require_mod = false

server_filter_tags = { "ai-assistant" }

configuration_options = {
    {
        name = "service_port",
        label = "Companion service port",
        hover = "The localhost port used by the server-side companion service.",
        options = {
            { description = "8765", data = 8765 },
            { description = "8766", data = 8766 },
            { description = "8767", data = 8767 },
        },
        default = 8765,
    },
}
