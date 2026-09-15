FROM ruby:3.3-slim-bookworm

ENV APP_HOME=/rails \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    RAILS_ENV=development

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y \
      build-essential \
      curl \
      ffmpeg \
      git \
      libpq-dev \
      libvips \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR ${APP_HOME}

COPY Gemfile Gemfile.lock* ./
RUN gem install bundler -v 4.0.20 --no-document
RUN bundle install

COPY . .
RUN chmod +x bin/docker-entrypoint

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
