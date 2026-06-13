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
workflow_bundle_dir="${workflow_bundle_dir:-$PWD/workflows}"
workflow_bundle_mount_path="/workflows"
workflow_bundle_state_file="/home/node/.n8n/.bundled-workflows.sha256"
opencode_config_path="${opencode_config_path:-$PWD/opencode.json}"
mcp_config_path="${mcp_config_path:-$PWD/.mcp.json}"
opencode_mcp_name="${opencode_mcp_name:-n8n-mcp}"

cloudflared_pid=""
cloudflared_bin=""

# ──────────────────────────────────────────────────
#  Color & icon helpers
# ──────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
    CHECK="${GREEN}✅${NC}"
    CROSS="${RED}❌${NC}"
    WARN="${YELLOW}⚠️${NC}"
    INFO="${BLUE}ℹ️${NC}"
    TOOL="${CYAN}🔧${NC}"
    KEY="${YELLOW}🔑${NC}"
    WRITE="${BLUE}📝${NC}"
    DOWNLOAD="${BLUE}📥${NC}"
    ROCKET="${MAGENTA}🚀${NC}"
    GLOBE="${CYAN}🌐${NC}"
    CLOCK="${BLUE}⏳${NC}"
    BROOM="${DIM}🧹${NC}"
    TRASH="${YELLOW}🗑️${NC}"
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; NC=''
    CHECK=''; CROSS=''; WARN=''; INFO=''; TOOL=''; KEY=''; WRITE=''; DOWNLOAD=''; ROCKET=''; GLOBE=''; CLOCK=''; BROOM=''; TRASH=''
fi

ensure_node_with_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    # Load nvm when already present so node can be discovered in this shell.
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090
        \. "$NVM_DIR/nvm.sh"
    fi

    if command -v node &> /dev/null; then
        echo -e "  ${CHECK} Node already installed: $(node -v)"
        if command -v npm &> /dev/null; then
            echo -e "  ${CHECK} npm version: $(npm -v)"
        fi
        return
    fi

    echo -e "  ${TOOL} Node not found — installing nvm and Node LTS (v${node_lts_version})..."

    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    fi

    # shellcheck disable=SC1090
    \. "$NVM_DIR/nvm.sh"
    nvm install "$node_lts_version"
    nvm use "$node_lts_version" >/dev/null

    echo -e "  ${CHECK} Node version: $(node -v)"
    echo -e "  ${CHECK} npm version: $(npm -v)"
}

ensure_opencode() {
    # Node + npm must already be installed; the main flow calls
    # ensure_node_with_nvm before this function. Bail out clearly
    # if npm is missing so we never fall back to the curl installer.
    if ! command -v npm &> /dev/null; then
        echo -e "  ${CROSS} npm not found — Node must be installed before opencode."
        exit 1
    fi

    # Make the active npm prefix's bin directory discoverable so the
    # freshly installed `opencode` binary is on PATH in this shell.
    npm_prefix_bin="$(npm config get prefix 2>/dev/null)/bin"
    if [ -d "$npm_prefix_bin" ]; then
        export PATH="$npm_prefix_bin:$HOME/.local/bin:$HOME/bin:$PATH"
    else
        export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
    fi

    if command -v opencode &> /dev/null; then
        echo -e "  ${CHECK} Opencode already installed: $(opencode --version 2>/dev/null || echo available)"
        return
    fi

    echo -e "  ${TOOL} Opencode not found — installing via npm (opencode-ai)..."
    npm i -g opencode-ai

    if command -v opencode &> /dev/null; then
        echo -e "  ${CHECK} Opencode installed successfully: $(opencode --version 2>/dev/null || echo available)"
    else
        echo -e "  ${CROSS} Opencode installation finished but command is still not available in PATH."
        echo -e "  ${INFO} Try opening a new shell, or add $npm_prefix_bin to your PATH."
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
                echo -e "  ${INFO} Loaded n8n MCP token from $config_path"
        fi
}

write_opencode_mcp_config() {
                local base_url="$1"
                local mcp_url="${base_url%/}/mcp-server/http"

        echo -e "  ${WRITE} Writing opencode MCP config to $opencode_config_path"

        mkdir -p "$(dirname "$opencode_config_path")"

        node - "$opencode_config_path" "$opencode_mcp_name" "$mcp_url" <<'NODE'
const fs = require('fs');

const [, , configPath, serverName, serverUrl] = process.argv;
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

// Always rewrite the n8n MCP entry so the URL tracks the current
// trycloudflare tunnel hostname. OAuth is delegated to the n8n MCP
// server (N8N_MCP_ACCESS_ENABLED=true on the container).
config.mcp[serverName] = {
    type: 'remote',
    url: serverUrl,
    oauth: {},
};

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

write_mcp_config() {
        local base_url="$1"
        local mcp_url="${base_url%/}/mcp-server/http"

        if [ -z "$n8n_mcp_access_token" ]; then
                echo -e "  ${WARN} n8n_mcp_access_token not set — skipping .mcp.json update."
                return
        fi

        echo -e "  ${WRITE} Writing MCP config to $mcp_config_path"

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
    echo -e "  ${TOOL} cloudflared not found — installing..."
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|arm) arch="arm" ;;
        *) echo -e "  ${CROSS} Unsupported architecture: $arch"; exit 1 ;;
    esac
    case "$os" in
        linux) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" ;;
        darwin) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${arch}" ;;
        *) echo -e "  ${CROSS} Unsupported OS: $os"; exit 1 ;;
    esac
    echo -e "  ${DOWNLOAD} Downloading cloudflared from $url"
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
    echo -e "  ${CHECK} cloudflared installed successfully."
}

if command -v cloudflared &> /dev/null; then
    cloudflared_bin="cloudflared"
else
    install_cloudflared
fi

ensure_node_with_nvm
ensure_opencode

if [ -n "${N8N_MCP_TOKEN:-}" ]; then
    echo -e "  ${WARN} N8N_MCP_TOKEN is not a documented n8n MCP environment variable and will not be used."
    echo -e "  ${INFO} n8n only documents N8N_MCP_MANAGED_BY_ENV and N8N_MCP_ACCESS_ENABLED for instance-level MCP settings."
fi

load_n8n_mcp_access_token_from_config "$opencode_config_path"
load_n8n_mcp_access_token_from_config "$mcp_config_path"

ensure_n8n_owner_password_hash() {
    if [ -n "$n8n_owner_password_hash" ]; then
        return
    fi

    echo -e "  ${KEY} Generating n8n owner password hash..."
    n8n_owner_password_hash=$(docker run --rm --entrypoint node "$n8n_docker_image" -e 'const bcrypt=require("/usr/local/lib/node_modules/n8n/node_modules/bcryptjs"); const pwd=process.argv[1]; if(!pwd){process.exit(1)}; process.stdout.write(bcrypt.hashSync(pwd, 10));' "$n8n_owner_password")

    if [ -z "$n8n_owner_password_hash" ]; then
        echo -e "  ${CROSS} Failed to generate n8n owner password hash"
        exit 1
    fi
}

cleanup() {
    echo -e "  ${BROOM} Cleaning up..."
    docker stop "$docker_container_name" >/dev/null 2>&1 || true
    docker rm "$docker_container_name" >/dev/null 2>&1 || true
    if [ -n "$cloudflared_pid" ] && kill -0 "$cloudflared_pid" 2>/dev/null; then
        kill "$cloudflared_pid" 2>/dev/null || true
    fi
    pkill -f "$cloudflared_bin tunnel --url http://localhost:$n8n_docker_port" >/dev/null 2>&1 || true
    echo -e "  ${CHECK} Cleanup complete."
}

remove_existing_container() {
    existing_container_id=$(docker ps -aq -f "name=^/${docker_container_name}$")
    if [ -n "$existing_container_id" ]; then
        echo -e "  ${TRASH} Removing existing container: $docker_container_name ($existing_container_id)"
        docker stop "$docker_container_name" >/dev/null 2>&1 || true
        docker rm "$docker_container_name" >/dev/null 2>&1 || true
    fi
}

compute_workflow_bundle_fingerprint() {
    if [ ! -d "$workflow_bundle_dir" ]; then
        return
    fi

    shopt -s nullglob
    local workflow_files=("$workflow_bundle_dir"/*.json)
    shopt -u nullglob

    if [ ${#workflow_files[@]} -eq 0 ]; then
        return
    fi

    {
        for workflow_file in "${workflow_files[@]}"; do
            sha256sum "$workflow_file"
        done
    } | sha256sum | awk '{print $1}'
}

import_bundled_workflows() {
    # Run import in a short-lived container BEFORE the daemon starts so there
    # is no SQLite write-lock conflict with the running n8n server process.
    if [ ! -d "$workflow_bundle_dir" ]; then
        echo -e "  ${INFO} No workflow bundle directory found at $workflow_bundle_dir; skipping import."
        return
    fi

    shopt -s nullglob
    local workflow_files=("$workflow_bundle_dir"/*.json)
    shopt -u nullglob

    if [ ${#workflow_files[@]} -eq 0 ]; then
        echo -e "  ${INFO} No bundled workflows found in $workflow_bundle_dir; skipping import."
        return
    fi

    local bundle_fingerprint
    bundle_fingerprint=$(compute_workflow_bundle_fingerprint)

    if [ -z "$bundle_fingerprint" ]; then
        echo -e "  ${WARN} Failed to compute workflow bundle fingerprint; skipping import."
        return
    fi

    # Check the fingerprint stored inside the persistent n8n data volume.
    local imported_fingerprint
    imported_fingerprint=$(docker run --rm \
        -v "$n8n_volume_name:/home/node/.n8n" \
        --entrypoint sh \
        "$n8n_docker_image" \
        -c "test -f '$workflow_bundle_state_file' && cat '$workflow_bundle_state_file'" 2>/dev/null || true)

    if [ "$imported_fingerprint" = "$bundle_fingerprint" ]; then
        echo -e "  ${CHECK} Bundled workflows already imported for this data volume."
        return
    fi

    echo -e "  ${TOOL} Importing bundled workflows from $workflow_bundle_dir"
    docker run --rm \
        -v "$n8n_volume_name:/home/node/.n8n" \
        -v "$workflow_bundle_dir:$workflow_bundle_mount_path:ro" \
        --entrypoint n8n \
        "$n8n_docker_image" \
        import:workflow \
        --separate \
        --input="$workflow_bundle_mount_path"

    # Persist the fingerprint so the import is skipped on subsequent restarts.
    docker run --rm \
        -v "$n8n_volume_name:/home/node/.n8n" \
        --entrypoint sh \
        "$n8n_docker_image" \
        -c "printf '%s\n' '$bundle_fingerprint' > '$workflow_bundle_state_file'"
    echo -e "  ${CHECK} Bundled workflows imported successfully."
}

trap cleanup exit int term

if ! docker info >/dev/null 2>&1; then
    echo -e "  ${CROSS} Docker is not running."
    exit 1
fi

ensure_n8n_owner_password_hash

echo -e "  ${GLOBE} Starting Cloudflare tunnel..."
tmp_log=$(mktemp)
$cloudflared_bin tunnel --url "http://localhost:$n8n_docker_port" --loglevel "$cloudflared_log_level" >"$tmp_log" 2>&1 &
cloudflared_pid=$!

tunnel_url=""
echo -e "  ${CLOCK} Waiting for tunnel URL..."
for i in $(seq 1 30); do
    tunnel_url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$tmp_log" | head -1)
    if [ -n "$tunnel_url" ]; then
        break
    fi
    sleep 1
done

rm -f "$tmp_log"

if [ -z "$tunnel_url" ]; then
    echo -e "  ${CROSS} Failed to get tunnel URL from cloudflared."
    exit 1
fi

echo -e "  ${CHECK} Tunnel URL: ${BOLD}${tunnel_url}${NC}"

n8n_host=$(echo "$tunnel_url" | sed -E -e 's|^https?://||')

docker volume create "$n8n_volume_name" >/dev/null 2>&1 || true

write_opencode_mcp_config "$tunnel_url"
write_mcp_config "$tunnel_url"

import_bundled_workflows

echo -e "  ${ROCKET} Starting n8n Docker container..."
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

# ──────────────────────────────────────────────────
#  Summary banner
# ──────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${GREEN}║         🚀  N8N  INSTANCE  READY                 ║${NC}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "  ${BOLD}${CYAN}🔗  URL${NC}"
echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
echo -e "  ${tunnel_url}"
echo ""

echo -e "  ${BOLD}${YELLOW}🔑  OWNER  LOGIN${NC}"
echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
printf "  ${BOLD}%-18s${NC} %s\n" "Email:"   "$n8n_owner_email"
printf "  ${BOLD}%-18s${NC} %s\n" "Password:" "$n8n_owner_password"
echo ""

echo -e "  ${BOLD}${MAGENTA}⚙️  INSTANCE  INFO${NC}"
echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
printf "  ${BOLD}%-22s${NC} %s\n" "Docker Container:" "$docker_container_name"
printf "  ${BOLD}%-22s${NC} %s\n" "Data Volume:"      "$n8n_volume_name"
printf "  ${BOLD}%-22s${NC} %s\n" "MCP Server:"       "${tunnel_url%/}/mcp-server/http"
echo ""

echo -e "  ${BOLD}${RED}🛑  STOP${NC}"
echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
echo -e "  Press ${BOLD}${RED}Ctrl+C${NC} to stop everything."
echo ""

# Uncomment the lines below for additional MCP / config details on first run:
# echo -e "  ${BOLD}${BLUE}📁  CONFIG  FILES${NC}"
# echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
# printf "  %-22s %s\n" "opencode config:" "$opencode_config_path"
# printf "  %-22s %s\n" "generic MCP config:" "$mcp_config_path"
# echo ""
# if [ -z "$n8n_mcp_access_token" ]; then
#   echo -e "  ${YELLOW}💡  Tip:${NC} Set ${BOLD}n8n_mcp_access_token${NC} to auto-write MCP client configs."
#   echo ""
# fi

# ──────────────────────────────────────────────────
#  Persist access info to N8N-ACCESS.md
#  (The terminal output of postStartCommand is easy
#  to miss in VS Code; a file is always visible in
#  the Explorer and supports clickable links.)
# ──────────────────────────────────────────────────
n8n_access_file="$PWD/N8N-ACCESS.md"
{
    echo "# 🚀 Your N8N Instance Is Ready"
    echo ""
    echo "Open the URL below in your browser and sign in with the credentials listed."
    echo ""
    echo "## 🔗 URL"
    echo ""
    echo "[$tunnel_url]($tunnel_url)"
    echo ""
    echo "## 🔑 Owner Login"
    echo ""
    echo "| Field    | Value |"
    echo "| -------- | ----- |"
    echo "| Email    | \`$n8n_owner_email\` |"
    echo "| Password | \`$n8n_owner_password\` |"
    echo ""
    echo "## ⚙️ Instance Info"
    echo ""
    echo "- **Docker container:** \`$docker_container_name\`"
    echo "- **Data volume:** \`$n8n_volume_name\`"
    echo "- **MCP server:** [${tunnel_url%/}/mcp-server/http](${tunnel_url%/}/mcp-server/http)"
    echo ""
    echo "## 🛑 Stop"
    echo ""
    echo "Press \`Ctrl+C\` in the codespace terminal to stop the instance."
    echo ""
    echo "---"
    echo ""
    echo "_This file is auto-generated by \`start-n8n.sh\` and is overwritten on each run._"
} > "$n8n_access_file"

echo -e "  ${INFO} Access info saved to: ${BOLD}$n8n_access_file${NC}"
echo -e "  ${INFO} Open it in VS Code to copy the URL, email, and password."
echo ""

while true; do
    sleep 1
done