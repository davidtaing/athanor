# Multi-stage build for the Athanor control plane (OTP app `athanor`).
# Produces a self-contained OTP release run by the runtime image.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20250520

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"

FROM ${BUILDER_IMAGE} AS builder

# Build deps for native compilation
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Cache deps
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Compile the app first so phoenix_live_view's colocated JS hooks
# (phoenix-colocated/athanor) are generated before esbuild bundles assets.
RUN mix compile
RUN mix assets.setup
RUN mix assets.deploy
RUN mix release

# Runtime image
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/athanor ./

USER nobody

EXPOSE 4000

CMD ["/app/bin/migrate_and_serve"]
