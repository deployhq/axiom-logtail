# frozen_string_literal: true

# Bundler derives the require path from the gem NAME. For a hyphenated gem it
# tries "axiom-logtail" and then, on LoadError, "axiom/logtail" -- never the
# underscored "axiom_logtail" this gem actually ships -- and then SWALLOWS the
# failure. The gemspec is still evaluated, and it require_relative's version.rb
# to read VERSION, so `AxiomLogtail` ends up defined as an empty module shell
# while every class inside it is missing.
#
# The result is a host app that boots fine and blows up with NameError only when
# something first touches AxiomLogtail::LogDevice -- which, in a Rails app, is
# while building the logger in config/environments/*.rb, before initializers run
# and often inside a rescue. Axiom then silently ships nothing.
#
# This shim makes the conventional `gem "axiom-logtail"` work with no `require:`
# option, so a consumer cannot fall into that trap by omission.
require_relative 'axiom_logtail'
