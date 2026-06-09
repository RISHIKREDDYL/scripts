#!/bin/bash
# ubuntu_bootstrap.sh
# Bootstrap script for a fresh Ubuntu VPS
# - Updates packages and handles non-interactive upgrades
# - Installs Python 3.12, Docker, Fail2ban, Ollama, Node.js
# - Adds helpful aliases globally

# Strict Mode:
# -e: Exit immediately if a command exits with a non-zero status
# -u: Treat unset variables as an error
# -o pipefail: Return value of a pipeline is the status of the last command to exit with a non-zero status
set -euo pipefail

# ANSI Color Codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Ensure the script is run with root privileges
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Please run this script as root (or with sudo).${NC}"
  exit 1
fi

# FIX: Explicitly set HOME for cloud-init environments
# Sudo contexts in some cloud providers may not preserve $HOME, breaking NVM/Pip installs
export HOME="/root"

echo -e "${YELLOW}1. Updating system...${NC}"

# Prevent apt from asking interactive questions during installation
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
# Upgrade packages; "--force-confdef" and "--force-confold" ensure existing config files 
# are kept to prevent the script from hanging on config merge prompts
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y software-properties-common
echo -e "${GREEN}System updated and PPA tools installed.${NC}"

echo -e "${YELLOW}2. Installing Python 3.12 and Base Tools...${NC}"

# Add Deadsnakes PPA to ensure Python 3.12 is available on older Ubuntu LTS versions
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update -y

# Install Python 3.12, venv (virtual environments), dev headers (for compiling pip packages),
# Docker container runtime, Curl (data transfer), and Git (version control)
apt-get install -y python3.12 python3.12-venv python3.12-dev python3-pip docker.io curl git

echo -e "${GREEN}Base tools (Python 3.12) installed.${NC}"

echo -e "${YELLOW}3. Installing and Configuring Fail2ban...${NC}"
apt-get install -y fail2ban

# Copy jail.conf to jail.local. 
# Modifications should be made in .local because .conf can be overwritten during package updates.
if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi
systemctl enable fail2ban
systemctl start fail2ban
echo -e "${GREEN}Fail2ban installed and active.${NC}"

echo -e "${YELLOW}4. Installing Ollama...${NC}"
# Check if the command exists to avoid redundant re-installation
if ! command -v ollama &> /dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
    echo -e "${GREEN}Ollama installed successfully.${NC}"
else
    echo -e "${GREEN}Ollama is already installed.${NC}"
fi

echo -e "${YELLOW}5. Installing Node.js via NVM...${NC}"

# NVM requires HOME to be set (handled at script start) to determine install location
export NVM_DIR="$HOME/.nvm"

# Install NVM (Node Version Manager)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

# Load NVM into the current shell session so we can use 'nvm' command immediately
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Install and activate Node.js version 24
nvm install 24
nvm use 24

echo -e "${GREEN}Node version: $(node -v)${NC}"
echo -e "${GREEN}NPM version: $(npm -v)${NC}"

echo -e "${YELLOW}6. Setting Timezone to Asia/Kolkata...${NC}"
timedatectl set-timezone Asia/Kolkata
echo -e "${GREEN}Timezone set to Asia/Kolkata.$(date)${NC}"

echo -e "${YELLOW}7. Adding aliases to /etc/bash.bashrc...${NC}"

# Modifying /etc/bash.bashrc ensures aliases are available globally for all users
BASHRC="/etc/bash.bashrc"

# Helper function to ensure idempotency (checks if line exists before adding)
add_alias() {
  local alias_line="$1"
  # grep -qxF: Quiet, Exact match, Fixed string (no regex)
  # The || ensures 'echo' runs only if grep fails to find the line
  grep -qxF "$alias_line" "$BASHRC" || echo "$alias_line" >> "$BASHRC"
}

add_alias "alias venv='python3.12 -m venv .venv'"
add_alias "alias act='source .venv/bin/activate'"

echo -e "${GREEN}Aliases added safely.${NC}"

echo "------------------"
echo -e "${GREEN}Bootstrap complete.${NC}"
echo "------------------"
