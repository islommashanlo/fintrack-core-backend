# frozen_string_literal: true

max_threads_count = ENV.fetch('RAILS_MAX_THREADS', 5).to_i
min_threads_count = ENV.fetch('RAILS_MIN_THREADS', max_threads_count).to_i
threads min_threads_count, max_threads_count

port ENV.fetch('PORT', 3000)

environment ENV.fetch('RAILS_ENV', 'development')

plugin :tmp_restart
