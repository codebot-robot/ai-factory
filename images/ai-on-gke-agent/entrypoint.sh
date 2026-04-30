#!/bin/bash
set -e

if [ -z "$AGENT_NAME" ]; then
  echo "AGENT_NAME environment variable is not set."
  exit 1
fi

echo "Cloning https://github.com/ai-on-gke/ai-factory.git..."
git clone https://github.com/ai-on-gke/ai-factory.git
cd ai-factory

export PROMPT_FILE=".agents/${AGENT_NAME}/agent.md"
if [ ! -f "$PROMPT_FILE" ]; then
  echo "Prompt file $PROMPT_FILE not found."
  exit 1
fi

if [ -n "$CRON_SCHEDULE" ]; then
  echo "Scheduling agent ${AGENT_NAME} with cron schedule: $CRON_SCHEDULE"
  
  # Export environment variables for cron
  export -p > /etc/environment.sh
  
  # Create a wrapper script to run gemini-cli with the correct working directory and environment
  cat << 'EOF' > /run_agent.sh
#!/bin/bash
source /etc/environment.sh
cd /ai-factory
echo "Running gemini-cli for agent ${AGENT_NAME} at $(date)..."
gemini-cli --yolo "$(cat "${PROMPT_FILE}")"
EOF
  chmod +x /run_agent.sh
  
  # Configure crontab
  echo "$CRON_SCHEDULE /run_agent.sh > /proc/1/fd/1 2>&1" > /tmp/agent-cron
  crontab /tmp/agent-cron
  
  # Start cron in the foreground
  exec cron -f
else
  echo "Running gemini-cli for agent ${AGENT_NAME}..."
  exec gemini-cli --yolo "$(cat "$PROMPT_FILE")"
fi