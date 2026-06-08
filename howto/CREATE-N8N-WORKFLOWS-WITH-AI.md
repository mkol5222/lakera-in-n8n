# HOWTO create n8n workflows with AI

## Prerequisites

- we assume Codespace environment based on [mkol5222/lakera-in-n8n](https://github.com/mkol5222/lakera-in-n8n)
- it has running N8N instance with public URL access provisioned e.g. https://estimated-lift-named-mandatory.trycloudflare.com/
- `start-n8n.sh` script also provisioned `opencode.json` config with N8n instance MCP server URL for OAuth authentication

## Steps

1. We assume [mkol5222/lakera-in-n8n](https://github.com/mkol5222/lakera-in-n8n) Codespace. Open new terminal in Codespace and authenticate N8N MCP server with command:
```shell
opencode mcp auth
```

2. Add MCP Context7 for documentation access with command (it will ask for authentication with Context7 account):
```shell
npx ctx7 setup --opencode -y
```

3. Check MCP servers with command:
```shell
opencode mcp list
```

4. Start your new opencode agent session with command:
```shell
opencode
```

5. Prompt your agent to create your first n8n workflow for your use case, e.g.:
```
Create new n8n workflow with manual trigger that is checking Public IP using ifconfig.me service.
```
