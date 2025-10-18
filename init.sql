-- Initialize database for FinTrack Rails application

-- Create database if it doesn't exist
-- (This is handled by the POSTGRES_DB environment variable)

-- Optional: Create additional users or setup
-- Uncomment if you need additional database users

-- CREATE USER fintrack_readonly WITH PASSWORD 'readonly_password';
-- GRANT CONNECT ON DATABASE fintrack TO fintrack_readonly;
-- GRANT USAGE ON SCHEMA public TO fintrack_readonly;
-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO fintrack_readonly;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO fintrack_readonly;
