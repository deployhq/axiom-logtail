# frozen_string_literal: true

require_relative "lib/axiom_logtail/version"

Gem::Specification.new do |spec|
  spec.name = "axiom-logtail"
  spec.version = AxiomLogtail::VERSION
  spec.authors = ["DeployHQ"]
  spec.license = "MIT"

  spec.summary = "Ship logtail events to Axiom, with credential redaction and bounded params"
  spec.description = <<~DESC
    An Axiom log device for the logtail gem, plus two pieces of hardening that
    logtail itself does not provide: recursive credential/PII redaction that
    reaches inside serialised-JSON values, and a size bound on the params
    carried by controller_called events.
  DESC

  spec.required_ruby_version = ">= 2.7.0"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "logtail", "~> 0.1"

  # Not a default gem from Ruby 3.4 onward, and `logtail` requires it without
  # declaring it. Without this the gem fails to load on modern Rubies.
  spec.add_dependency "base64", "~> 0.2"

  spec.add_development_dependency "rspec", "~> 3.0"

  spec.metadata["rubygems_mfa_required"] = "true"
end
