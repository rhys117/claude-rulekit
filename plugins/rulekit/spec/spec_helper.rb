# The suite drives the hooks the way Claude Code does: a JSON event on stdin,
# stdout and the exit code back. Nothing in bin/ is loaded in-process.
#
#   cd plugins/rulekit && bundle install && bundle exec rspec

require_relative 'support/hook_result'
require_relative 'support/project'
require_relative 'support/fake_judge'

RSpec.configure do |config|
  config.order = :random
  Kernel.srand config.seed

  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }

  # A scenario is a sequence of hook calls with several things to check about
  # each; report every failed check, not only the first.
  config.define_derived_metadata { |metadata| metadata[:aggregate_failures] = true }
end

# Nothing on stdout: the hook had nothing to say to the agent.
RSpec::Matchers.define :be_silent do
  match { |result| result.stdout.empty? }
  failure_message { |result| "expected no stdout, got: #{result.stdout}" }
end

# The rule is named in what the hook sent back.
RSpec::Matchers.define :fire do |rule|
  match { |result| result.stdout.include?("[#{rule}]") }
  failure_message { |result| "expected [#{rule}] to fire, got: #{result.stdout.inspect}" }
  failure_message_when_negated { |result| "expected [#{rule}] not to fire, got: #{result.stdout}" }
end
