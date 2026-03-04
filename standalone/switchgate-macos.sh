#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROXY_PORT=8888
CONFIG_FILE="$PWD/tinyproxy.conf"
PID_FILE="$PWD/tinyproxy.pid"
LOG_FILE="$PWD/proxy.log"
PROXY_PID=""

echo -e "${BLUE}SwitchGate - Network Gateway for Nintendo Switch${NC}"
echo "=============================================="

if ! command -v tinyproxy &> /dev/null; then
    echo -e "${RED}Error: tinyproxy is not installed${NC}"
    echo -e "${YELLOW}Please install it with: brew install tinyproxy${NC}"
    exit 1
fi

BREW_PREFIX="$(brew --prefix)"

get_local_ip() {
    local local_ip
    local_ip=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n1)
    echo "$local_ip"
}

create_config() {
    echo -e "${YELLOW}Creating configuration file...${NC}"
    cat > "$CONFIG_FILE" << EOF
# SwitchGate - TinyProxy configuration
Port $PROXY_PORT
Listen 0.0.0.0
Timeout 600
DefaultErrorFile "${BREW_PREFIX}/share/tinyproxy/default.html"
StatFile "${BREW_PREFIX}/share/tinyproxy/stats.html"
Logfile "$LOG_FILE"
LogLevel Info
PidFile "$PID_FILE"
MaxClients 100
Allow 192.168.0.0/16
Allow 10.0.0.0/8
Allow 172.16.0.0/12
DisableViaHeader Yes
EOF
    echo -e "${GREEN}Configuration file created${NC}"
}

check_port() {
    if lsof -Pi :$PROXY_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${RED}Port $PROXY_PORT is already in use!${NC}"
        echo -e "${YELLOW}Stopping existing process...${NC}"
        lsof -ti:$PROXY_PORT | xargs kill
        sleep 2
        if lsof -Pi :$PROXY_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo -e "${YELLOW}Process still running, forcing stop...${NC}"
            lsof -ti:$PROXY_PORT | xargs kill -9
            sleep 1
        fi
    fi
}

start_proxy() {
    echo -e "${YELLOW}Starting proxy...${NC}"
    check_port
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
    tinyproxy -c "$CONFIG_FILE" -d &
    PROXY_PID=$!
    sleep 3
    if kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "$PROXY_PID" > "$PID_FILE"
        echo -e "${GREEN}Proxy started successfully!${NC}"
        return 0
    else
        echo -e "${RED}Failed to start proxy${NC}"
        return 1
    fi
}

show_info() {
    local local_ip
    local_ip=$(get_local_ip)
    echo ""
    if [ -z "$local_ip" ]; then
        echo -e "${RED}WARNING: Could not detect local IP address.${NC}"
        echo -e "${YELLOW}Make sure you are connected to a Wi-Fi network.${NC}"
        echo ""
    fi
    echo -e "${GREEN}NINTENDO SWITCH CONFIGURATION:${NC}"
    echo "=========================================="
    echo -e "${BLUE}Proxy IP:${NC} ${local_ip:-<not detected>}"
    echo -e "${BLUE}Port:${NC} $PROXY_PORT"
    echo ""
    echo -e "${YELLOW}HOW TO CONFIGURE ON SWITCH:${NC}"
    echo "1. Go to Settings > Internet"
    echo "2. Select your Wi-Fi network"
    echo "3. Choose 'Change settings'"
    echo "4. In 'Proxy server' choose 'Yes'"
    echo "5. Enter IP: ${local_ip:-<not detected>}"
    echo "6. Enter Port: $PROXY_PORT"
    echo "7. Save and test connection"
    echo ""
    echo -e "${GREEN}Proxy Status:${NC}"
    echo "- Log file: $LOG_FILE"
    echo "- PID file: $PID_FILE"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to stop the proxy${NC}"
    echo ""
}

monitor_logs() {
    echo -e "${BLUE}Monitoring logs (Ctrl+C to exit):${NC}"
    echo "=================================================="

    local retries=0
    while [ ! -f "$LOG_FILE" ] && [ $retries -lt 10 ]; do
        sleep 1
        retries=$((retries + 1))
    done

    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        echo -e "${YELLOW}Log file not created yet. Waiting for proxy...${NC}"
        wait "$PROXY_PID" 2>/dev/null
    fi
}

main() {
    create_config
    echo ""
    if start_proxy; then
        show_info
        monitor_logs
    else
        echo -e "${RED}Failed to start proxy. Check logs.${NC}"
        exit 1
    fi
}

cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping proxy...${NC}"
    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID"
        wait "$PROXY_PID" 2>/dev/null
        echo -e "${GREEN}Proxy stopped${NC}"
    elif [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            echo -e "${GREEN}Proxy stopped${NC}"
        fi
    fi
    rm -f "$PID_FILE" "$CONFIG_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM

main
