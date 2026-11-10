# frozen_string_literal: true

class ActivityMethodology
  def self.definition
    @definition ||= YAML.safe_load_file(Rails.root.join("config/activity_methodology.yml"))
    @definition.deep_dup
  end

  def self.window_days
    definition.fetch("clusters").fetch("window_days")
  end

  def self.minimum_insiders
    definition.fetch("clusters").fetch("minimum_insiders")
  end
end
