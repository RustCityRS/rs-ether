# syntax=docker/dockerfile:1
#
# Multi-stage build producing a self-contained OTP release of rs-ether.
# The result is a plain `mix release` (no Burrito) so the image stays slim and
# the build needs no Zig. Native single-file binaries are built separately
# (BURRITO_BUILD=1) from the same release definition.

ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.3
ARG DEBIAN_VERSION=bookworm-20250428-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
    && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

RUN mkdir config
COPY config/config.exs config/runtime.exs config/
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile
RUN mix release rs_ether

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/rs_ether ./

USER nobody

# `start` runs the BEAM in the foreground so an orchestrator's signal reaches it
# directly. To migrate first, override with:
#   docker run ... rs_ether eval "RsEther.Release.migrate()"
ENTRYPOINT ["/app/bin/rs_ether"]
CMD ["start"]
