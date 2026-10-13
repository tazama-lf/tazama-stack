#!/bin/bash
# filepath: ./tazama-biar.sh

cd "$(dirname "$0")"

BIAR_PROJECT="tazama-biar"

pause() {
    read -rp " Press Enter to continue..."
}

env_value() {
    [[ -f ./.env ]] || return 0
    grep -E "^$1=" ./.env | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r'
}

# Show which NiFi authentication mode (NIFI_AUTH in .env) the next deploy uses.
nifi_auth_status() {
    local mode port https_port bind
    mode=$(env_value NIFI_AUTH)
    mode=$(echo "${mode:-none}" | tr '[:upper:]' '[:lower:]')
    port=$(env_value NIFI_PORT)
    https_port=$(env_value NIFI_HTTPS_PORT)
    bind=$(env_value NIFI_BIND_ADDRESS)
    bind=${bind:-127.0.0.1}

    case "$mode" in
        none)
            if [[ "$bind" == "127.0.0.1" ]]; then
                echo " NiFi auth: none  (http://localhost:${port:-8088}/nifi, this machine only)"
            else
                echo " NiFi auth: none  (http://localhost:${port:-8088}/nifi, NO LOGIN, open on ${bind})"
            fi
            ;;
        keycloak)
            echo " NiFi auth: keycloak  (https://localhost:${https_port:-8443}/nifi, needs core Authentication)"
            ;;
        *)
            echo " NiFi auth: ${mode}  (unsupported; set NIFI_AUTH to none or keycloak in .env)"
            ;;
    esac
}

# Verify tazama-core is reachable via its NATS exterior port (14222).
# SERVER_A_HOST defaults to localhost for single-machine; set to the private
# IP in .env for AWS multi-host deployments.
check_core_reachable() {
    local server_a_host="localhost"

    if [[ -f ./.env ]]; then
        local env_host
        env_host=$(grep -E '^SERVER_A_HOST=' ./.env | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        if [[ -n "$env_host" ]]; then
            server_a_host="$env_host"
        fi
    fi

    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$server_a_host" 14222 >/dev/null 2>&1
    else
        timeout 3 bash -c ">/dev/tcp/${server_a_host}/14222" >/dev/null 2>&1
    fi

    if [[ $? -ne 0 ]]; then
        echo ""
        echo " ERROR: tazama-core is not reachable at ${server_a_host}:14222"
        echo "        Ensure tazama-core is running and SERVER_A_HOST is set correctly in .env"
        echo ""
        pause
        return 1
    fi
    return 0
}

deploy_biar_hub() {
    echo ""
    echo " Deploying BIAR stack (DockerHub images)..."
    echo ""
    docker compose -p "$BIAR_PROJECT" \
        -f ./docker-compose.biar.infrastructure.yaml \
        -f ./docker-compose.hub.biar.yaml \
        -f ./docker-compose.utils.init.yaml \
        up -d

    echo ""
    echo " Done."
    pause
}

deploy_biar_dev() {
    echo ""
    echo " Deploying BIAR stack (GitHub builds)..."
    echo ""
    docker compose -p "$BIAR_PROJECT" \
        -f ./docker-compose.biar.infrastructure.yaml \
        -f ./docker-compose.dev.biar.yaml \
        -f ./docker-compose.utils.init.yaml \
        up -d

    echo ""
    echo " Done."
    pause
}

down_biar() {
    echo ""
    echo " Tearing down BIAR stack..."
    echo ""
    docker compose -p "$BIAR_PROJECT" \
        -f ./docker-compose.biar.infrastructure.yaml \
        -f ./docker-compose.hub.biar.yaml \
        -f ./docker-compose.dev.biar.yaml \
        -f ./docker-compose.utils.init.yaml \
        down --volumes

    echo ""
    echo " Done."
    pause
}

utils() {
    while true; do
        clear
        echo ""
        echo " Utilities:"
        echo "   1. Tear down BIAR"
        echo "   b. Back"
        echo ""
        read -rp " Select option: " util

        case "$util" in
            b|B) return ;;
            1) down_biar ;;
        esac
    done
}

menu() {
    while true; do
        clear
        echo ""
        echo "============================================================"
        echo " Tazama BIAR Launcher"
        echo "============================================================"
        echo ""
        echo " Pre-requisite: tazama-core must be running on Server A"
        nifi_auth_status
        echo ""
        echo "   1. Deploy BIAR stack (DockerHub images)"
        echo "   2. Deploy BIAR stack (GitHub builds)"
        echo "   3. Utilities / teardown"
        echo ""
        read -rp " Select option (1-3), or (q)uit: " choice

        case "$choice" in
            q|Q) exit 0 ;;
            1) check_core_reachable && deploy_biar_hub ;;
            2) check_core_reachable && deploy_biar_dev ;;
            3) utils ;;
        esac
    done
}

menu
