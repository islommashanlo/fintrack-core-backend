# FinTrack Rails Backend - Docker Setup

This guide explains how to run the FinTrack Rails backend using Docker for local development, testing, and production deployment.

## Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+
- Git

## Quick Start

### Development Environment

1. **Clone the repository**
   ```bash
   git clone <your-repo-url>
   cd fintrack-core-backend
   ```

2. **Start the development environment**
   ```bash
   # Start all services (Rails app, PostgreSQL, Redis, Sidekiq)
   docker-compose -f docker-compose.dev.yml up -d

   # Or start with logs visible
   docker-compose -f docker-compose.dev.yml up
   ```

3. **Run database migrations**
   ```bash
   # The Rails app container will automatically run migrations on first start
   # If you need to run them manually:
   docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:prepare
   ```

4. **Access the application**
   - Rails app: http://localhost:3001
   - Health check: http://localhost:3001/health
   - Database admin (pgAdmin): http://localhost:5050 (admin@fintrack.local / admin)
   - Redis admin (Redis Commander): http://localhost:8081
   - Mail catcher: http://localhost:1080

### Production Environment

```bash
# Build and start production services
docker-compose up -d --build

# Scale the web service if needed
docker-compose up -d --scale web=3
```

## Docker Compose Files

### Main Files

- **`docker-compose.yml`** - Production-ready setup with PostgreSQL, Redis, and Rails app
- **`docker-compose.dev.yml`** - Development environment with hot reloading and additional tools
- **`docker-compose.test.yml`** - Testing environment with isolated services
- **`docker-compose.override.yml`** - Development overrides (loaded automatically)

### Services Included

#### Development (`docker-compose.dev.yml`)
- **web** - Rails application with hot reloading
- **db** - PostgreSQL database (port 5433)
- **redis** - Redis cache/server (port 6380)
- **sidekiq** - Background job processor
- **mailcatcher** - Email testing tool
- **redis-commander** - Redis GUI admin

#### Production (`docker-compose.yml`)
- **web** - Rails application
- **db** - PostgreSQL database (port 5432)
- **redis** - Redis cache/server (port 6379)
- **sidekiq** - Background job processor
- **rails_admin** - pgAdmin for database management

#### Testing (`docker-compose.test.yml`)
- **test_app** - Rails app configured for testing
- **test_db** - PostgreSQL test database (port 5434)
- **test_redis** - Redis for testing (port 6381)
- **test_sidekiq** - Sidekiq for testing (optional)

## Common Commands

### Development

```bash
# Start all development services
docker-compose -f docker-compose.dev.yml up -d

# View logs
docker-compose -f docker-compose.dev.yml logs -f web

# Execute Rails commands
docker-compose -f docker-compose.dev.yml exec web bundle exec rails console
docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:migrate
docker-compose -f docker-compose.dev.yml exec web bundle exec rspec

# Access Rails console
docker-compose -f docker-compose.dev.yml exec web bundle exec rails console

# Run tests
docker-compose -f docker-compose.test.yml run --rm test_app

# Stop all services
docker-compose -f docker-compose.dev.yml down

# Clean up (removes volumes and containers)
docker-compose -f docker-compose.dev.yml down -v --remove-orphans
```

### Production

```bash
# Start production services
docker-compose up -d

# View logs
docker-compose logs -f

# Scale web servers
docker-compose up -d --scale web=3

# Update and restart services
docker-compose up -d --build

# Stop all services
docker-compose down
```

## Environment Variables

### Required Environment Variables

Create a `.env` file in the project root:

```bash
# Database
DATABASE_URL=postgresql://fintrack:fintrack@db:5432/fintrack

# Redis
REDIS_URL=redis://redis:6379/0

# Rails
RAILS_ENV=development
SECRET_KEY_BASE=your-secret-key-here

# External services (for production)
# STRIPE_PUBLISHABLE_KEY=pk_...
# STRIPE_SECRET_KEY=sk_...
# SENDGRID_API_KEY=SG...
```

### Development Environment Variables

The development setup uses these defaults:
- Database: `fintrack_development` on port 5433
- Redis: port 6380
- Rails app: port 3001

## Database Management

### Development

```bash
# Access PostgreSQL directly
docker-compose -f docker-compose.dev.yml exec db psql -U fintrack -d fintrack_development

# Run migrations
docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:migrate

# Reset database
docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:reset

# Seed database
docker-compose -f docker-compose.dev.yml exec web bundle exec rails db:seed
```

### Production

```bash
# Access pgAdmin
# URL: http://localhost:5050
# Email: admin@fintrack.local
# Password: admin

# Run migrations
docker-compose exec web bundle exec rails db:migrate

# Backup database
docker-compose exec db pg_dump -U fintrack fintrack > backup.sql
```

## Troubleshooting

### Common Issues

1. **Port conflicts**
   ```bash
   # Check if ports are in use
   lsof -i :3000
   lsof -i :5432

   # Use different ports if needed
   PORT=3001 docker-compose -f docker-compose.dev.yml up
   ```

2. **Permission issues**
   ```bash
   # Fix permissions on bind mounts
   sudo chown -R $USER:$USER .
   ```

3. **Database connection issues**
   ```bash
   # Check if database is healthy
   docker-compose -f docker-compose.dev.yml ps

   # Reset database
   docker-compose -f docker-compose.dev.yml down -v
   docker-compose -f docker-compose.dev.yml up -d
   ```

4. **Bundle install fails**
   ```bash
   # Clean bundle cache and retry
   docker-compose -f docker-compose.dev.yml exec web rm -rf /usr/local/bundle/cache
   docker-compose -f docker-compose.dev.yml exec web bundle install
   ```

### Logs and Debugging

```bash
# View all logs
docker-compose -f docker-compose.dev.yml logs

# View specific service logs
docker-compose -f docker-compose.dev.yml logs web

# Follow logs in real-time
docker-compose -f docker-compose.dev.yml logs -f web

# Access container shell for debugging
docker-compose -f docker-compose.dev.yml exec web bash
```

## Performance Optimization

### Development

- Use `tmpfs` for temporary files (enabled in test environment)
- Mount volumes with `:cached` for better performance on macOS
- Use `spring` or `bootsnap` for faster Rails startup

### Production

- Use multi-stage builds to reduce image size
- Enable gzip compression
- Use Redis for session storage
- Implement proper caching strategies

## Security Considerations

- Never commit `.env` files with real credentials
- Use secrets management in production (Docker secrets, Kubernetes secrets, etc.)
- Regularly update base images and dependencies
- Run security scans on images: `docker scan <image>`

## Integration with Scrapers

The Rails backend is designed to work with the Python scrapers microservice:

1. **API Integration**: Scrapers send data to `/api/ingest/trades`
2. **Authentication**: Use API keys for scraper authentication
3. **Network**: Both services should be on the same Docker network

Example `docker-compose` setup:

```yaml
version: '3.8'
services:
  rails:
    # ... Rails configuration
    networks:
      - fintrack

  scrapers:
    # ... Scrapers configuration
    networks:
      - fintrack

networks:
  fintrack:
    driver: bridge
```

## Additional Resources

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Rails on Docker Guide](https://docs.docker.com/samples/rails/)
- [PostgreSQL Docker Image](https://hub.docker.com/_/postgres)
- [Redis Docker Image](https://hub.docker.com/_/redis)
