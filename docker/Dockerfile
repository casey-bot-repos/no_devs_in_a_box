FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq gnupg \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends \
      gh nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Headless Chrome for target repos' own Playwright/Puppeteer/Cypress test
# suites, so `npm test` works out of the box with zero per-repo config.
# Deliberately NOT `apt install chromium` — Ubuntu's chromium package is a
# snap wrapper that doesn't run in a container. Playwright's installer
# fetches a real binary plus the OS shared libs any headless Chromium
# needs, which also benefits Puppeteer/other frameworks' own browser
# downloads. Best-effort: a repo pinned to a very different Playwright
# version may still trigger its own (network) download.
RUN npx --yes playwright install --with-deps chromium

WORKDIR /factory
COPY orchestrator/ ./orchestrator/
COPY roles/ ./roles/
COPY scripts/ ./scripts/
COPY docker/entrypoint.sh ./entrypoint.sh
RUN chmod +x entrypoint.sh orchestrator/*.sh orchestrator/lib/*.sh scripts/*.sh

ENTRYPOINT ["./entrypoint.sh"]
