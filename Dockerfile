##############################
# Stage 1: monolith-builder
##############################
FROM docker.io/rust:1.81-bullseye AS monolith-builder
# Build the Rust binary (monolith) – only the resulting binary is needed later.
RUN set -eux && cargo install --locked monolith

##############################
# Stage 2: build
##############################
FROM node:18.18-bullseye-slim AS build
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /data

# Copy files required for dependency installation.
COPY package.json yarn.lock playwright.config.ts ./

# Install dependencies with a cache mount.
RUN --mount=type=cache,target=/usr/local/share/.cache/yarn \
    set -eux && \
    yarn install --network-timeout 10000000 && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy the monolith binary from the Rust builder.
COPY --from=monolith-builder /usr/local/cargo/bin/monolith /usr/local/bin/monolith

# Install Playwright (with its dependencies) and clean up caches.
RUN set -eux && \
    npx playwright install --with-deps chromium && \
    yarn cache clean

# Copy the entire source code (including your scripts folder).
COPY . .

# Run build steps (e.g. generate Prisma client and build the app).
RUN yarn prisma generate && yarn build

##############################
# Stage 3: runtime
##############################
FROM node:18.18-bullseye-slim AS runtime
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /var/www/html

# Copy package files.
COPY --from=build /data/package.json /data/yarn.lock ./

# Install minimal runtime dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set production environment.
ENV NODE_ENV=production

# Install only production dependencies.
RUN yarn install --frozen-lockfile --production && yarn cache clean

# Install ts-node globally and ensure its binary is in the PATH.
RUN yarn global add ts-node
ENV PATH="/usr/local/share/.config/yarn/global/node_modules/.bin:${PATH}"

# Copy built assets and other necessary directories from the build stage.
# (Assuming your Next.js build output is in .next.)
COPY --from=build /data/.next ./.next
COPY --from=build /data/prisma ./prisma
# Also copy the scripts folder so that worker.ts is available.
COPY --from=build /data/scripts ./scripts
# Copy the monolith binary.
COPY --from=build /usr/local/bin/monolith /usr/local/bin/monolith

# (Optional) Copy any public assets if needed.
# COPY --from=build /data/public ./public

# Healthcheck for the container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD [ "curl", "--silent", "--fail", "http://127.0.0.1:3000/" ]

EXPOSE 3000

# Run any pending migrations, then start the application.
CMD yarn prisma migrate deploy && yarn start
