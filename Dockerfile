# Development and test image.
#   docker compose run --rm test                                  # whole suite
#   RUBY_VERSION=3.1 docker compose run --rm test                 # another Ruby
#   GRAPHQL_VERSION="~> 2.4.0" docker compose run --rm test       # another graphql
#   GRAPHQL_ARMORY_ENGINE=next docker compose run --rm test       # Execution::Next (graphql >= 2.5.26)
ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git libsqlite3-dev libyaml-dev \
 && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/bundle \
    BUNDLE_JOBS=4

WORKDIR /app
