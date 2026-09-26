FROM erlang:29.1.0.0-alpine AS build

# hadolint ignore=DL3018
RUN apk add --no-cache bash build-base git

WORKDIR /src

COPY . .

ENV ERL_FLAGS="-enable-feature all"

RUN rebar3 as prod release

FROM erlang:29.1.0.0-alpine

WORKDIR /app
RUN chown 1000:1000 /app

COPY --from=build --chown=1000:1000 /src/_build/prod/rel/es_xp ./

ENV HOME=/app \
    ERL_FLAGS="-enable-feature all"

EXPOSE 8080

USER 1000:1000

ENTRYPOINT ["/app/bin/es_xp"]
CMD ["foreground"]
