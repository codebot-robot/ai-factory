#!/bin/bash
set -e

if [ -z "$AGENT_NAME" ]; then
  echo "AGENT_NAME environment variable is not set."
  exit 1
fi

while true; do
  echo "Cloning https://github.com/ai-on-gke/ai-factory.git..."
  if [ -d "ai-factory" ]; then
    rm -rf ai-factory
  fi
  git clone https://github.com/ai-on-gke/ai-factory.git
  cd ai-factory

  PROMPT_FILE=".agents/${AGENT_NAME}/agent.md"
  if [ ! -f "$PROMPT_FILE" ]; then
    echo "Prompt file $PROMPT_FILE not found."
    exit 1
  fi

  echo "Running gemini-cli for agent ${AGENT_NAME}..."
  gemini-cli --yolo "$(cat $PROMPT_FILE)" || true

  cd ..
  
  if [ -z "$AGENT_SCHEDULE_SECONDS" ]; then
    break
  fi
  
  echo "Sleeping for $AGENT_SCHEDULE_SECONDS seconds before next run..."
  sleep "$AGENT_SCHEDULE_SECONDS"
done
