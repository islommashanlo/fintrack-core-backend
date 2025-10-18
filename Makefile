.PHONY: help dev prod test build clean logs shell console migrate seed reset-db

# Default target
help: ## Show this help message
	@echo "FinTrack Rails Backend - Docker Commands"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Development commands
dev: ## Start development environment
	docker-compose -f docker-compose.dev.yml up -d

dev-up: ## Start development environment with logs
	docker-compose -f docker-compose.dev.yml up

dev-down: ## Stop development environment
	docker-compose -f docker-compose.dev.yml down

dev-logs: ## View development logs
	docker-compose -f docker-compose.dev.yml logs -f

# Production commands
prod: ## Start production environment
	docker-compose up -d

prod-up: ## Start production environment with logs
	docker-compose up

prod-down: ## Stop production environment
	docker-compose down

prod-logs: ## View production logs
	docker-compose logs -f

# Testing commands
test: ## Run tests
	docker-compose -f docker-compose.test.yml run --rm test_app

test-up: ## Start test environment
	docker-compose -f docker-compose.test.yml up -d

test-down: ## Stop test environment
	docker-compose -f docker-compose.test.yml down

# Database commands
migrate: ## Run database migrations
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:migrate

seed: ## Seed database
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:seed

reset-db: ## Reset database (WARNING: destroys data)
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:reset

prepare-db: ## Prepare database (create, migrate, seed)
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:prepare

# Rails commands
console: ## Open Rails console
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails console

shell: ## Open shell in Rails container
	docker-compose -f docker-compose.dev.yml exec web bash

routes: ## Show Rails routes
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails routes

# Build commands
build: ## Build Docker images
	docker-compose -f docker-compose.dev.yml build

build-prod: ## Build production Docker images
	docker-compose build

# Cleanup commands
clean: ## Remove containers and volumes
	docker-compose -f docker-compose.dev.yml down -v --remove-orphans

clean-all: ## Remove all containers, volumes, and images
	docker-compose -f docker-compose.dev.yml down -v --remove-orphans --rmi all

# Status commands
status: ## Show container status
	docker-compose -f docker-compose.dev.yml ps

health: ## Check health of services
	@echo "Checking Rails app health..."
	@curl -f http://localhost:3001/health || echo "Rails app not healthy"
	@echo "Checking database..."
	@docker-compose -f docker-compose.dev.yml exec db pg_isready -U fintrack || echo "Database not ready"
	@echo "Checking Redis..."
	@docker-compose -f docker-compose.dev.yml exec redis redis-cli ping || echo "Redis not ready"

# Quick setup for new development environment
setup: ## Complete setup for new development environment
	@echo "Setting up development environment..."
	$(MAKE) dev
	@echo "Waiting for services to be ready..."
	@sleep 30
	$(MAKE) prepare-db
	@echo "Development environment ready!"
	@echo "Rails app: http://localhost:3001"
	@echo "Health check: http://localhost:3001/health"
	@echo "Database admin: http://localhost:5050 (admin@fintrack.local / admin)"
	@echo "Redis admin: http://localhost:8081"
	@echo "Mail catcher: http://localhost:1080"

# Scale commands
scale-web: ## Scale web containers (usage: make scale-web COUNT=3)
	docker-compose -f docker-compose.dev.yml up -d --scale web=$(COUNT)

# Logs for specific services
logs-web: ## View Rails app logs
	docker-compose -f docker-compose.dev.yml logs -f web

logs-db: ## View database logs
	docker-compose -f docker-compose.dev.yml logs -f db

logs-redis: ## View Redis logs
	docker-compose -f docker-compose.dev.yml logs -f redis

logs-sidekiq: ## View Sidekiq logs
	docker-compose -f docker-compose.dev.yml logs -f sidekiq

# Database backup/restore
backup-db: ## Backup database
	docker-compose -f docker-compose.dev.yml exec db pg_dump -U fintrack fintrack_development > backup_$$(date +%Y%m%d_%H%M%S).sql

restore-db: ## Restore database (usage: make restore-db FILE=backup.sql)
	docker-compose -f docker-compose.dev.yml exec -T db psql -U fintrack fintrack_development < $(FILE)

# Bundle commands
bundle-install: ## Install Ruby gems
	docker-compose -f docker-compose.dev.yml exec web bundle install

bundle-update: ## Update Ruby gems
	docker-compose -f docker-compose.dev.yml exec web bundle update

# Asset compilation
assets-precompile: ## Precompile assets for production
	docker-compose -f docker-compose.dev.yml exec web bundle exec rails assets:precompile

# RSpec commands
rspec: ## Run RSpec tests
	docker-compose -f docker-compose.dev.yml exec web bundle exec rspec

rspec-spec: ## Run specific RSpec test file (usage: make rspec-spec FILE=spec/models/user_spec.rb)
	docker-compose -f docker-compose.dev.yml exec web bundle exec rspec $(FILE)

# Rubocop
rubocop: ## Run Rubocop
	docker-compose -f docker-compose.dev.yml exec web bundle exec rubocop

rubocop-fix: ## Run Rubocop with auto-fix
	docker-compose -f docker-compose.dev.yml exec web bundle exec rubocop -a
