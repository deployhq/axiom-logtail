# frozen_string_literal: true

require 'axiom_logtail'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  # Configuration is global state; a leaked key list would silently change what
  # later examples redact.
  config.after { AxiomLogtail.reset_config! }
end
