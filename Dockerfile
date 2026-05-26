FROM elixir:1.17-otp-27-slim

RUN apt-get update -y && apt-get install -y git && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=dev
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock* ./
RUN mix deps.get && mix deps.compile

COPY config/ config/
COPY lib/ lib/
COPY priv/ priv/

RUN mix compile

CMD mix ecto.create 2>/dev/null; mix ecto.migrate && mix run --no-halt
