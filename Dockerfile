# Use the specific Ruby version from Gemfile
FROM ruby:3.4.7-slim

# Set environment variables
ENV RAILS_ENV=development \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        nodejs \
        postgresql-client \
        git \
        curl \
        vim && \
    rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Install bundler
RUN gem install bundler -N

# Copy Gemfile and install dependencies
COPY Gemfile Gemfile.lock ./
RUN bundle config set force_ruby_platform true && \
    bundle install --jobs 4 --retry 3

# Copy application code
COPY . .

# Precompile assets for production (optional, can be skipped for development)
# RUN bundle exec rake assets:precompile

# Create non-root user for security
RUN groupadd -r rails && useradd -r -g rails rails
RUN chown -R rails:rails /app
USER rails

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Start the application
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]


