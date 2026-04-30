FROM node:20-slim

RUN apt-get update && \
    apt-get install -y git cron procps && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @google/gemini-cli

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]