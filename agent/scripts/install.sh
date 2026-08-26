#!/usr/bin/env sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
agent_binary=${1:-"$script_dir/../dist/easyprivacy-agent"}
service_file="$script_dir/../packaging/easyprivacy-agent.service"

if [ ! -f "$agent_binary" ]; then
  echo "Agent binary not found: $agent_binary" >&2
  echo "Pass the compiled Linux agent as the first argument." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Version 0.1 requires a systemd-based Linux server." >&2
  exit 1
fi

if ! getent group easyprivacy >/dev/null 2>&1; then
  groupadd --system easyprivacy
fi
if ! getent passwd easyprivacy >/dev/null 2>&1; then
  useradd --system --gid easyprivacy --home-dir /var/lib/easyprivacy \
    --shell /usr/sbin/nologin easyprivacy
fi

install -m 0755 "$agent_binary" /usr/local/bin/easyprivacy-agent
install -d -m 0700 -o easyprivacy -g easyprivacy /var/lib/easyprivacy
install -m 0644 "$service_file" /etc/systemd/system/easyprivacy-agent.service

if [ ! -f /var/lib/easyprivacy/agent.token ]; then
  token_output=$(runuser -u easyprivacy -- \
    /usr/local/bin/easyprivacy-agent init --state-dir /var/lib/easyprivacy)
else
  token_output="Agent was already initialized; the existing token was preserved."
fi

systemctl daemon-reload
systemctl enable --now easyprivacy-agent.service

printf '%s\n' "$token_output"
echo
echo "The agent is listening only on 127.0.0.1:7443."
echo "Use an SSH tunnel for development or configure an HTTPS reverse proxy before remote access."
echo
echo "After independently verifying this server's SSH host key, enroll a distinct device with:"
echo "sudo -u easyprivacy /usr/local/bin/easyprivacy-agent device enroll \"
echo "  --state-dir /var/lib/easyprivacy --name 'This device'"
echo "The device credential is printed once; the shared token above remains development-only."
