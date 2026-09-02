FROM node:22.18.0-alpine@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22.18.0-alpine@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b
ENV NODE_ENV=production
WORKDIR /app
RUN addgroup -S cloud && adduser -S -G cloud cloud
COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json ./
COPY migrations ./migrations
COPY public ./public
COPY scripts ./scripts
COPY src ./src
USER cloud
EXPOSE 8080
CMD ["sh", "-c", "node scripts/migrate.mjs && exec node src/server.mjs"]
