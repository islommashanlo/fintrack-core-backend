FROM ruby:3.2

WORKDIR /app

RUN apt-get update -y && apt-get install -y build-essential libpq-dev nodejs && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./

RUN gem install bundler -N && bundle config set force_ruby_platform true && bundle install || true

COPY . .

EXPOSE 3000

CMD ["bash", "-lc", "bundle exec puma -C config/puma.rb"]


