# frozen_string_literal: true

# The same deterministic pipeline as live 13F work, on a queue that cannot outrank
# live Form 4 or live 13F jobs.
class ParseForm13fBackfillJob < ParseForm13fJob
  queue_as :sec_backfill_13f
end
