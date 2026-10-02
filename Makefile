# Local development runs in containers. podman-compose is the default;
# use `make COMPOSE="docker compose" ...` for Docker.
COMPOSE ?= podman-compose
RUN = $(COMPOSE) run --rm web

.PHONY: help setup build up down test lint lint-fix console shell rails logs ps

help: ## List targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.env:
	cp .env.example .env

setup: .env build ## Build the image, start Postgres and Redis, prepare the databases
	$(COMPOSE) up -d db redis
	$(RUN) bin/rails db:prepare

build: ## Rebuild the dev image (needed after Gemfile changes)
	$(COMPOSE) build web

up: .env ## Start web and Sidekiq (the SEC poller stays off unless EDGAR_POLLING=on)
	$(COMPOSE) up -d

down: ## Stop everything
	$(COMPOSE) down

test: ## Run specs; one file or line with SPEC=spec/services/sec_client_spec.rb:12
	$(RUN) bundle exec rspec $(SPEC)

lint: ## Run rubocop
	$(RUN) bin/rubocop

lint-fix: ## Run rubocop with safe autocorrect
	$(RUN) bin/rubocop -a

console: ## Rails console
	$(RUN) bin/rails console

shell: ## Shell in the app container
	$(RUN) bash

rails: ## Any rails or rake task: make rails T="validate:report"
	$(RUN) bin/rails $(T)

logs: ## Follow logs
	$(COMPOSE) logs -f

ps: ## Container status
	$(COMPOSE) ps
