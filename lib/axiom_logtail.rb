# frozen_string_literal: true

require 'logtail'

require 'axiom_logtail/version'
require 'axiom_logtail/configuration'
require 'axiom_logtail/log_device'
require 'axiom_logtail/bounded_params'

# `logtail-rack` is optional -- an app can use the Axiom sink without the Rack
# middleware. Header filtering is only meaningful when it is present.
begin
  require 'logtail-rack'
  require 'axiom_logtail/header_filters'
rescue LoadError
  # no-op: HeaderFilters is simply unavailable
end

module AxiomLogtail
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config)
      config.reset_matcher!
      config
    end

    # Test seam; also useful in a console.
    def reset_config!
      @config = nil
    end

    def header_filters?
      defined?(HeaderFilters) ? true : false
    end
  end
end
