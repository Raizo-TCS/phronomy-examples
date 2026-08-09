# syntax=docker/dockerfile:1
# check=error=true

# Build from the phronomy-examples repository root so the shared
# Gemfile.phronomy is available:
#   docker build -f 20_cve_scanner/Dockerfile -t cve_scanner_tmp .
#   docker run -d -p 80:3000 -e RAILS_MASTER_KEY=<value> --name cve_scanner_tmp cve_scanner_tmp

ARG RUBY_VERSION=3.2.3
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Each application Gemfile evals the repository-level Gemfile.phronomy.
# Keep the same absolute layout in the image: /rails/Gemfile -> /Gemfile.phronomy.
COPY Gemfile.phronomy /Gemfile.phronomy
COPY 20_cve_scanner/vendor/* ./vendor/
COPY 20_cve_scanner/Gemfile 20_cve_scanner/Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

COPY 20_cve_scanner/. .

RUN bundle exec bootsnap precompile -j 1 app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY --chown=rails:rails --from=build /Gemfile.phronomy /Gemfile.phronomy

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server"]
