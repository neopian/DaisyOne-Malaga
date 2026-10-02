FROM node:24-alpine
WORKDIR /app/backend
COPY backend/package*.json ./
RUN npm ci --omit=dev --ignore-scripts && mkdir -p /app/data/uploads && chown -R node:node /app
COPY --chown=node:node backend/src ./src
COPY --chown=node:node config /app/config
COPY --chown=node:node backend/migrations ./migrations
USER node
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080 UPLOAD_DIR=/app/data/uploads
EXPOSE 8080
CMD ["node", "src/server.mjs"]
