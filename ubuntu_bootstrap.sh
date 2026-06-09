#!/bin/bash
# ubuntu_bootstrap.sh
# Bootstrap script for a fresh Ubuntu VPS
# - Updates packages
# - Installs Python tooling
# - Adds helpful aliases

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Please run this script as root (or with sudo).${NC}"
  exit 1
fi

echo -e "${YELLOW}1. Updating system...${NC}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
echo -e "${GREEN}System updated.${NC}"

echo -e "${YELLOW}2. Installing Python tools and Docker...${NC}"
apt-get install -y python3 python3-pip python3-venv docker.io
echo -e "${GREEN}Python installed.${NC}"

echo -e "${YELLOW}3. Setting Timezone to Asia/Kolkata...${NC}"
timedatectl set-timezone Asia/Kolkata
echo -e "${GREEN}Timezone set to Asia/Kolkata.$(date)${NC}"

echo -e "${YELLOW}4. Adding aliases to ~/.bashrc...${NC}"

BASHRC="/etc/bash.bashrc"

add_alias() {
  local alias_line="$1"
  grep -qxF "$alias_line" "$BASHRC" || echo "$alias_line" >> "$BASHRC"
}

add_alias "alias venv='python3 -m venv .venv'"
add_alias "alias act='source .venv/bin/activate'"

echo -e "${GREEN}Aliases added safely.${NC}"

echo "------------------"
echo -e "${GREEN}Bootstrap complete.${NC}"
echo "------------------"
echo "Run: source /etc/bash.bashrc or reopen your SSH session."
