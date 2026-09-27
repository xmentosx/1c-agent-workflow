FROM node:22-alpine
WORKDIR /app
COPY mcp-tools-list-proxy.js /app/mcp-tools-list-proxy.js
COPY vendor/toon-4.1.1 /app/vendor/toon-4.1.1
USER node
ENTRYPOINT ["node", "/app/mcp-tools-list-proxy.js"]
