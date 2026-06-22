#!/bin/bash
set -e

# ──────────────────────────────────────────────────
#  Guard: GitHub Codespaces only
# ──────────────────────────────────────────────────
if [ "${CODESPACES:-}" != "true" ]; then
    echo "❌ start-n8n.sh requires GitHub Codespaces."
    echo "   Open this repo in a Codespace to run n8n."
    exit 1
fi

docker_container_name="n8n"
n8n_docker_image="n8nio/n8n"
n8n_docker_port=5678
n8n_basic_auth_password="${n8n_basic_auth_password:-AdminIzK1ng}"
node_lts_version="24"
n8n_owner_email="${n8n_owner_email:-guru@nowhere.local}"
n8n_owner_first_name="${n8n_owner_first_name:-Admin}"
n8n_owner_last_name="${n8n_owner_last_name:-User}"
n8n_owner_password="${n8n_owner_password:-$n8n_basic_auth_password}"
n8n_owner_password_hash="${n8n_owner_password_hash:-}"
n8n_mcp_access_token="${n8n_mcp_access_token:-}"
n8n_volume_name="${n8n_volume_name:-n8n_data}"
workflow_bundle_dir="${workflow_bundle_dir:-$PWD/workflows}"
workflow_bundle_mount_path="/workflows"
workflow_bundle_state_file="/home/node/.n8n/.bundled-workflows.sha256"
opencode_config_path="${opencode_config_path:-$PWD/opencode.json}"
mcp_config_path="${mcp_config_path:-$PWD/.mcp.json}"
opencode_mcp_name="${opencode_mcp_name:-n8n-mcp}"

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
    NC='\033[0m'
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
    if ! command -v npm &> /dev/null; then
        echo -e "  ${CROSS} npm not found — Node must be installed before opencode."
        exit 1
    fi

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
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) config = parsed;
    } catch (error) {
        console.error(`error: failed to parse ${configPath}: ${error.message}`);
        process.exit(1);
    }
}
if (!config.$schema) config.$schema = defaultConfig.$schema;
if (!config.mcp || typeof config.mcp !== 'object' || Array.isArray(config.mcp)) config.mcp = {};
config.mcp[serverName] = { type: 'remote', url: serverUrl, oauth: {} };
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
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) config = parsed;
    } catch (error) {
        console.error(`error: failed to parse ${configPath}: ${error.message}`);
        process.exit(1);
    }
}
if (!config.mcpServers || typeof config.mcpServers !== 'object' || Array.isArray(config.mcpServers)) config.mcpServers = {};
config.mcpServers[serverName] = {
    type: 'http',
    url: serverUrl,
    headers: { Authorization: `Bearer ${accessToken}` },
};
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

# ──────────────────────────────────────────────────
#  Codespaces public port URL
# ──────────────────────────────────────────────────
setup_codespaces_url() {
    if [ -z "${CODESPACE_NAME:-}" ] || [ -z "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
        echo -e "  ${CROSS} Missing Codespaces env vars (CODESPACE_NAME, GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN)."
        exit 1
    fi

    tunnel_url="https://${CODESPACE_NAME}-${n8n_docker_port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"

    echo -e "  ${GLOBE} Making port ${n8n_docker_port} public..."
    if gh codespace ports visibility "${n8n_docker_port}:public" -c "${CODESPACE_NAME}" 2>/dev/null; then
        echo -e "  ${CHECK} Port ${n8n_docker_port} is public."
    else
        echo -e "  ${WARN} Could not set port visibility automatically."
        echo -e "  ${INFO} Open the ${BOLD}Ports${NC} panel in VS Code and set port ${n8n_docker_port} to ${BOLD}Public${NC}."
    fi

    echo -e "  ${CHECK} n8n URL: ${BOLD}${tunnel_url}${NC}"
}

ensure_n8n_owner_password_hash() {
    if [ -n "$n8n_owner_password_hash" ]; then
        return
    fi

    echo -e "  ${KEY} Generating n8n owner password hash..."
    n8n_owner_password_hash=$(docker run --rm --entrypoint node "$n8n_docker_image" \
        -e 'const bcrypt=require("/usr/local/lib/node_modules/n8n/node_modules/bcryptjs"); const pwd=process.argv[1]; if(!pwd){process.exit(1)}; process.stdout.write(bcrypt.hashSync(pwd, 10));' \
        "$n8n_owner_password")

    if [ -z "$n8n_owner_password_hash" ]; then
        echo -e "  ${CROSS} Failed to generate n8n owner password hash"
        exit 1
    fi
}

cleanup() {
    echo -e "  ${BROOM} Stopping n8n container..."
    docker kill "$docker_container_name" >/dev/null 2>&1 || true
    docker rm "$docker_container_name" >/dev/null 2>&1 || true
    echo -e "  ${CHECK} Done."
}

remove_existing_container() {
    existing_container_id=$(docker ps -aq -f "name=^/${docker_container_name}$")
    if [ -n "$existing_container_id" ]; then
        echo -e "  ${TRASH} Removing existing container: $docker_container_name ($existing_container_id)"
        docker kill "$docker_container_name" >/dev/null 2>&1 || true
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

    docker run --rm \
        -v "$n8n_volume_name:/home/node/.n8n" \
        --entrypoint sh \
        "$n8n_docker_image" \
        -c "printf '%s\n' '$bundle_fingerprint' > '$workflow_bundle_state_file'"
    echo -e "  ${CHECK} Bundled workflows imported successfully."
}

trap cleanup EXIT INT TERM

if ! docker info >/dev/null 2>&1; then
    echo -e "  ${CROSS} Docker is not running."
    exit 1
fi

ensure_node_with_nvm
ensure_opencode

load_n8n_mcp_access_token_from_config "$opencode_config_path"
load_n8n_mcp_access_token_from_config "$mcp_config_path"

echo -e "  ${DOWNLOAD} Pulling n8n Docker image (${n8n_docker_image})..."
docker pull "$n8n_docker_image"
echo -e "  ${CHECK} n8n image ready."

ensure_n8n_owner_password_hash

setup_codespaces_url

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
    -e N8N_PUSH_BACKEND="sse" \
    -e NODE_ENV="development" \
    "$n8n_docker_image"

echo -e "  ${CLOCK} Waiting for n8n to be accessible..."
n8n_accessible=false
for i in $(seq 1 60); do
    http_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "$tunnel_url/" 2>/dev/null || echo "000")
    echo -n "  Attempt $i: HTTP $http_status"
    if [ "$http_status" = "200" ] || [ "$http_status" = "401" ]; then
        n8n_accessible=true
        echo ""
        break
    fi
    sleep 2
    echo -n "."
done
echo ""

if [ "$n8n_accessible" != "true" ]; then
    echo -e "  ${WARN} n8n did not become accessible within the timeout."
    echo -e "  ${INFO} Container logs: docker logs $docker_container_name"
fi

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
printf "  ${BOLD}%-18s${NC} %s\n" "Email:"    "$n8n_owner_email"
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

# ──────────────────────────────────────────────────
#  Persist access info to N8N-ACCESS.md
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
    echo "Press \`Ctrl+C\` in the Codespace terminal to stop the instance."
    echo ""
    echo "---"
    echo ""
    echo "_This file is auto-generated by \`start-n8n.sh\` and is overwritten on each run._"
} > "$n8n_access_file"

echo -e "  ${INFO} Access info saved to: ${BOLD}$n8n_access_file${NC}"
echo ""

while true; do
    sleep 1
done
