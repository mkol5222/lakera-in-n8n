#!/bin/bash
set -e

docker_container_name="n8n-cloudflared"
cloudflared_log_level="info"
n8n_docker_image="n8nio/n8n"
n8n_docker_port=5678
n8n_basic_auth_user="${n8n_basic_auth_user:-admin}"
n8n_basic_auth_password="${n8n_basic_auth_password:-AdminIzK1ng}"
node_lts_version="24"
n8n_owner_email="${n8n_owner_email:-guru@nowhere.local}"
n8n_owner_first_name="${n8n_owner_first_name:-Admin}"
n8n_owner_last_name="${n8n_owner_last_name:-User}"
n8n_owner_password="${n8n_owner_password:-$n8n_basic_auth_password}"
n8n_owner_password_hash="${n8n_owner_password_hash:-}"
n8n_mcp_access_token="${n8n_mcp_access_token:-}"
n8n_data_dir="${n8n_data_dir:-$PWD/.n8n}"
n8n_volume_name="${n8n_volume_name:-n8n_data}"
opencode_config_path="${opencode_config_path:-$PWD/opencode.json}"
mcp_config_path="${mcp_config_path:-$PWD/.mcp.json}"
opencode_mcp_name="${opencode_mcp_name:-n8n-mcp}"

cloudflared_pid=""
cloudflared_bin=""

ensure_node_with_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    # Load nvm when already present so node can be discovered in this shell.
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090
        \. "$NVM_DIR/nvm.sh"
    fi

    if command -v node &> /dev/null; then
        echo "node already installed: $(node -v)"
        if command -v npm &> /dev/null; then
            echo "npm version: $(npm -v)"
        fi
        return
    fi

    echo "node not found. installing nvm and node lts (${node_lts_version})..."

    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    fi

    # shellcheck disable=SC1090
    \. "$NVM_DIR/nvm.sh"
    nvm install "$node_lts_version"
    nvm use "$node_lts_version" >/dev/null

    echo "node version: $(node -v)"
    echo "npm version: $(npm -v)"
}

ensure_opencode() {
    export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$PATH"

    if command -v opencode &> /dev/null; then
        echo "opencode already installed: $(opencode --version 2>/dev/null || echo available)"
        return
    fi

    echo "opencode not found. installing..."
    curl -fsSL https://opencode.ai/install | bash

    # Some installers place binaries in user-local paths not present in non-login shells.
    export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$PATH"

    if [ ! -x "$HOME/.opencode/bin/opencode" ]; then
        detected_opencode_path=$(find "$HOME" -maxdepth 5 -type f -name opencode 2>/dev/null | head -n 1)
        if [ -n "$detected_opencode_path" ]; then
            export PATH="$(dirname "$detected_opencode_path"):$PATH"
        fi
    fi

    if command -v opencode &> /dev/null; then
        echo "opencode installed successfully: $(opencode --version 2>/dev/null || echo available)"
    else
        echo "error: opencode installation finished but command is still not available in PATH."
        echo "try opening a new shell, or add ~/.local/bin to your PATH."
        exit 1
    fi
}

load_n8n_mcp_access_token_from_config() {
    local config_path="$1"

    if [ -n "$n8n_mcp_access_token" ] || [ ! -f "$config_path" ]; then
        return
    fi

    n8n_mcp_access_token=$(node - "$config_path" "$opencode_mcp_name" <<'NODE'
const fs = require('fs');

const [, , configPath, serverName] = process.argv;

try {
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const authHeader = config?.mcp?.[serverName]?.headers?.Authorization
        ?? config?.mcp?.[serverName]?.auth?.headerValue;
    if (typeof authHeader === 'string') {
        process.stdout.write(authHeader.replace(/^Bearer\s+/i, ''));
    }
} catch (error) {
    process.stderr.write(`warning: failed to read MCP token from ${configPath}: ${error.message}\n`);
}
NODE
)

        if [ -n "$n8n_mcp_access_token" ]; then
                echo "loaded n8n MCP token from $config_path"
        fi
}

write_opencode_mcp_config() {
                local base_url="$1"
                local mcp_url="${base_url%/}/mcp-server/http"

        if [ -z "$n8n_mcp_access_token" ]; then
                echo "n8n_mcp_access_token not set. skipping opencode MCP config update."
                return
        fi

        echo "writing opencode MCP config to $opencode_config_path"

        mkdir -p "$(dirname "$opencode_config_path")"

        node - "$opencode_config_path" "$opencode_mcp_name" "$mcp_url" "$n8n_mcp_access_token" <<'NODE'
const fs = require('fs');

const [, , configPath, serverName, serverUrl, accessToken] = process.argv;
const defaultConfig = { $schema: 'https://opencode.ai/config.json', mcp: {} };

let config = defaultConfig;

if (fs.existsSync(configPath)) {
    try {
        const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            config = parsed;
        }
    } catch (error) {
        console.error(`error: failed to parse ${configPath}: ${error.message}`);
        process.exit(1);
    }
}

if (!config.$schema) {
    config.$schema = defaultConfig.$schema;
}

if (!config.mcp || typeof config.mcp !== 'object' || Array.isArray(config.mcp)) {
    config.mcp = {};
}

config.mcp[serverName] = {
    type: 'remote',
    url: serverUrl,
    oauth: false,
    headers: {
        Authorization: `Bearer ${accessToken}`,
    },
};

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

write_mcp_config() {
        local base_url="$1"
        local mcp_url="${base_url%/}/mcp-server/http"

        if [ -z "$n8n_mcp_access_token" ]; then
                echo "n8n_mcp_access_token not set. skipping .mcp.json update."
                return
        fi

        echo "writing MCP config to $mcp_config_path"

        mkdir -p "$(dirname "$mcp_config_path")"

        node - "$mcp_config_path" "$opencode_mcp_name" "$mcp_url" "$n8n_mcp_access_token" <<'NODE'
const fs = require('fs');

const [, , configPath, serverName, serverUrl, accessToken] = process.argv;
const defaultConfig = { mcpServers: {} };

let config = defaultConfig;

if (fs.existsSync(configPath)) {
    try {
        const parsed = JSON.parse(fs.readFileSync(configPath, 'utf8'));
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            config = parsed;
        }
    } catch (error) {
        console.error(`error: failed to parse ${configPath}: ${error.message}`);
        process.exit(1);
    }
}

if (!config.mcpServers || typeof config.mcpServers !== 'object' || Array.isArray(config.mcpServers)) {
    config.mcpServers = {};
}

config.mcpServers[serverName] = {
    type: 'http',
    url: serverUrl,
    headers: {
        Authorization: `Bearer ${accessToken}`,
    },
};

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

install_cloudflared() {
    echo "cloudflared not found. installing..."
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|arm) arch="arm" ;;
        *) echo "error: unsupported architecture: $arch"; exit 1 ;;
    esac
    case "$os" in
        linux) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" ;;
        darwin) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${arch}" ;;
        *) echo "error: unsupported os: $os"; exit 1 ;;
    esac
    echo "downloading cloudflared from $url"
    if [ -w /usr/local/bin ]; then
        curl -sL "$url" -o /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
        cloudflared_bin="cloudflared"
    elif command -v sudo &> /dev/null; then
        curl -sL "$url" -o /tmp/cloudflared
        sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
        sudo chmod +x /usr/local/bin/cloudflared
        cloudflared_bin="cloudflared"
    else
        curl -sL "$url" -o ./cloudflared
        chmod +x ./cloudflared
        cloudflared_bin="./cloudflared"
    fi
    echo "cloudflared installed successfully."
}

if command -v cloudflared &> /dev/null; then
    cloudflared_bin="cloudflared"
else
    install_cloudflared
fi

ensure_node_with_nvm
ensure_opencode

if [ -n "${N8N_MCP_TOKEN:-}" ]; then
    echo "warning: N8N_MCP_TOKEN is not a documented n8n MCP environment variable and will not be used."
    echo "n8n only documents N8N_MCP_MANAGED_BY_ENV and N8N_MCP_ACCESS_ENABLED for instance-level MCP settings."
fi

load_n8n_mcp_access_token_from_config "$opencode_config_path"
load_n8n_mcp_access_token_from_config "$mcp_config_path"

ensure_n8n_owner_password_hash() {
    if [ -n "$n8n_owner_password_hash" ]; then
        return
    fi

    echo "generating n8n owner password hash..."
    n8n_owner_password_hash=$(docker run --rm --entrypoint node "$n8n_docker_image" -e 'const bcrypt=require("/usr/local/lib/node_modules/n8n/node_modules/bcryptjs"); const pwd=process.argv[1]; if(!pwd){process.exit(1)}; process.stdout.write(bcrypt.hashSync(pwd, 10));' "$n8n_owner_password")

    if [ -z "$n8n_owner_password_hash" ]; then
        echo "error: failed to generate n8n owner password hash"
        exit 1
    fi
}

cleanup() {
    echo "cleaning up..."
    docker stop "$docker_container_name" >/dev/null 2>&1 || true
    docker rm "$docker_container_name" >/dev/null 2>&1 || true
    if [ -n "$cloudflared_pid" ] && kill -0 "$cloudflared_pid" 2>/dev/null; then
        kill "$cloudflared_pid" 2>/dev/null || true
    fi
    pkill -f "$cloudflared_bin tunnel --url http://localhost:$n8n_docker_port" >/dev/null 2>&1 || true
    echo "cleanup complete."
}

remove_existing_container() {
    existing_container_id=$(docker ps -aq -f "name=^/${docker_container_name}$")
    if [ -n "$existing_container_id" ]; then
        echo "removing existing container: $docker_container_name ($existing_container_id)"
        docker stop "$docker_container_name" >/dev/null 2>&1 || true
        docker rm "$docker_container_name" >/dev/null 2>&1 || true
    fi
}

trap cleanup exit int term

if ! docker info >/dev/null 2>&1; then
    echo "error: docker is not running."
    exit 1
fi

ensure_n8n_owner_password_hash

echo "starting cloudflare tunnel..."
tmp_log=$(mktemp)
$cloudflared_bin tunnel --url "http://localhost:$n8n_docker_port" --loglevel "$cloudflared_log_level" >"$tmp_log" 2>&1 &
cloudflared_pid=$!

tunnel_url=""
echo "waiting for tunnel url..."
for i in $(seq 1 30); do
    tunnel_url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$tmp_log" | head -1)
    if [ -n "$tunnel_url" ]; then
        break
    fi
    sleep 1
done

rm -f "$tmp_log"

if [ -z "$tunnel_url" ]; then
    echo "error: failed to get tunnel url from cloudflared."
    exit 1
fi

echo "tunnel url: $tunnel_url"

n8n_host=$(echo "$tunnel_url" | sed -E -e 's|^https?://||')

docker volume create "$n8n_volume_name" >/dev/null 2>&1 || true

write_opencode_mcp_config "$tunnel_url"
write_mcp_config "$tunnel_url"

echo "starting n8n docker container..."
remove_existing_container
docker run -d \
    --name "$docker_container_name" \
    -p "$n8n_docker_port:$n8n_docker_port" \
    -v "$n8n_volume_name:/home/node/.n8n" \
    -e N8N_EDITOR_BASE_URL="$tunnel_url" \
    -e N8N_HOST="$n8n_host" \
    -e N8N_PROTOCOL="https" \
    -e WEBHOOK_URL="$tunnel_url" \
    -e N8N_PROXY_HOPS="1" \
    -e N8N_INSTANCE_OWNER_MANAGED_BY_ENV="true" \
    -e N8N_INSTANCE_OWNER_EMAIL="$n8n_owner_email" \
    -e N8N_INSTANCE_OWNER_FIRST_NAME="$n8n_owner_first_name" \
    -e N8N_INSTANCE_OWNER_LAST_NAME="$n8n_owner_last_name" \
    -e N8N_INSTANCE_OWNER_PASSWORD_HASH="$n8n_owner_password_hash" \
    -e N8N_MCP_MANAGED_BY_ENV="true" \
    -e N8N_MCP_ACCESS_ENABLED="true" \
    "$n8n_docker_image"

echo ""
echo "n8n is running at: $tunnel_url"
echo "owner login: $n8n_owner_email / $n8n_owner_password"
echo "n8n data dir: $n8n_data_dir (docker volume: $n8n_volume_name)"
if [ -n "$n8n_mcp_access_token" ]; then
    echo "opencode MCP config: $opencode_config_path"
    echo "generic MCP config: $mcp_config_path"
    echo "opencode MCP server: $opencode_mcp_name -> ${tunnel_url%/}/mcp-server/http"
    echo "note: n8n_mcp_access_token updates client config only; n8n must already know this token."
else
    echo "set n8n_mcp_access_token to also write MCP client config into $opencode_config_path and $mcp_config_path"
    echo "generate the MCP access token once in n8n UI at Settings > Instance-level MCP > Connection details > Access Token"
fi
echo "docker container: $docker_container_name"
echo "press ctrl+c to stop everything."
echo ""

while true; do
    sleep 1
done