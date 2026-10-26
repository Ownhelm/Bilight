FROM node:24-bookworm-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig*.json vite.config.ts index.html ./
COPY shared ./shared
COPY server ./server
COPY src ./src
COPY branding ./branding
COPY tests ./tests
RUN npm run build && npm prune --omit=dev

FROM node:24-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3880 DATA_DIR=/data BILIGHT_KEY_FILE=/run/secrets/master_key BILIGHT_DROP_PRIVILEGES=1
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/dist ./dist
COPY --from=build /app/dist-server ./dist-server
COPY LICENSE THIRD_PARTY_NOTICES.md ./
COPY docs/licenses ./licenses
RUN mkdir /data && chown node:node /data
EXPOSE 3880
CMD ["node", "dist-server/server/index.js"]
