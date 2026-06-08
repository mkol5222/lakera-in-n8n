# HOWTO create n8n workflows with AI

## Prerequisites

- we assume Codespace environment based on [mkol5222/lakera-in-n8n](https://github.com/mkol5222/lakera-in-n8n)
- it has running N8N instance with public URL access provisioned e.g. https://estimated-lift-named-mandatory.trycloudflare.com/
- `start-n8n.sh` script also provisioned `opencode.json` config with N8n instance MCP server URL for OAuth authentication

## Steps

1. Open new terminal and authenticate N8N MCP server with command:
````shell
opencode mcp auth
```

2. Check MCP servers with command:
````shell
opencode mcp list
```

3. Start your new opencode agent session with command:
````shell
opencode
```



