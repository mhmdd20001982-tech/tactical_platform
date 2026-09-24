FROM node:22-bookworm-slim AS build

WORKDIR /app
COPY protocol/package*.json ./protocol/
COPY server/package*.json ./server/
RUN npm install --prefix protocol && npm install --prefix server

COPY protocol/tsconfig.json protocol/
COPY protocol/src protocol/src
COPY server/tsconfig.json server/
COPY server/src server/src
RUN npm run build

FROM node:22-bookworm-slim AS runtime

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=8080
ENV HEARTBEAT_MS=30000
WORKDIR /app

COPY --from=build /app/protocol/package*.json ./protocol/
COPY --from=build /app/protocol/dist ./protocol/dist
COPY --from=build /app/server/package*.json ./server/
COPY --from=build /app/server/dist ./server/dist
RUN npm install --omit=dev --prefix protocol && npm install --omit=dev --prefix server

EXPOSE 8080
USER node
CMD ["node", "server/dist/server.js"]
