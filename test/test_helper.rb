ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/model_factories"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Model tests build only the records needed for each example. This keeps
    # the relational constraints explicit and avoids coupling tests to a
    # global fixture graph.
    include ModelFactories
  end
end
