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

# Copy only the files needed for installing dependencies.
COPY package.json yarn.lock playwright.config.ts ./

# Use a cache mount for Yarn to speed up repeated builds.
RUN --mount=type=cache,target=/usr/local/share/.cache/yarn \
    set -eux && \
    yarn install --network-timeout 10000000 && \
    # Install curl and ca-certificates (needed for playwright and healthcheck)
    apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy the monolith binary from the Rust builder.
COPY --from=monolith-builder /usr/local/cargo/bin/monolith /usr/local/bin/monolith

# Install Playwright and clean up caches.
RUN set -eux && \
    npx playwright install --with-deps chromium && \
    yarn cache clean

# Copy the rest of your source code.
COPY . .

# Run build steps (e.g. Prisma generation and the build script).
RUN yarn prisma generate && yarn build

##############################
# Stage 3: runtime
##############################
FROM node:18.18-bullseye-slim AS runtime
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /var/www/html

# Install minimal runtime dependencies: copy package files and install production deps.
COPY --from=build /data/package.json /data/yarn.lock ./
# (Re)install curl and certificates for the healthcheck and runtime.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set production environment so only production dependencies are installed.
ENV NODE_ENV=production

RUN yarn install --frozen-lockfile --production && yarn cache clean

# Copy the built assets and other necessary files from the build stage.
COPY --from=build /data/dist ./dist
COPY --from=build /data/prisma ./prisma
# (If you have an environment file, copy it as well – adjust as needed)
# COPY --from=build /data/.env ./.env

# Also copy the monolith binary from the builder stage.
COPY --from=build /usr/local/bin/monolith /usr/local/bin/monolith

# (Optional) If you have any public assets or additional directories, copy them here.
# COPY --from=build /data/public ./public

# Healthcheck for the container.
HEALTHCHECK --interval=30s \
            --timeout=5s \
            --start-period=10s \
            --retries=3 \
            CMD [ "curl", "--silent", "--fail", "http://127.0.0.1:3000/" ]

EXPOSE 3000

CMD yarn prisma migrate deploy && yarn start
