if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
  end
  SimpleCov.at_exit do
    SimpleCov.result.format!
  end
end

$testing = true

FLAPJACK_ENV    = ENV["FLAPJACK_ENV"] || 'test'
FLAPJACK_ROOT   = File.join(File.dirname(__FILE__), '..')
FLAPJACK_CONFIG = File.join(FLAPJACK_ROOT, 'etc', 'flapjack_config.yaml')
ENV['RACK_ENV'] = ENV["FLAPJACK_ENV"]

require 'bundler'
Bundler.require(:default, :test)

require 'webmock/rspec'
WebMock.disable_net_connect!

$:.unshift(File.dirname(__FILE__) + '/../lib')
require 'flapjack/configuration'


# Requires supporting files with custom matchers and macros, etc,
# in ./support/ and its subdirectories.
Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each {|f| require f}

class MockLogger
  attr_accessor :messages, :errors

  def initialize
    @messages = []
    @errors   = []
  end

  %w(debug info warn).each do |level|
    class_eval <<-RUBY
      def #{level}(msg)
        @messages << '#{level.upcase}' + ': ' + msg
      end
    RUBY
  end

  %w(error fatal).each do |level|
    class_eval <<-ERRORS
      def #{level}(msg)
        @messages << '#{level.upcase}' + ': ' + msg
        @errors   << '#{level.upcase}' + ': ' + msg
      end
    ERRORS
  end

  %w(debug info warn error fatal).each do |level|
    class_eval <<-LEVELS
      def #{level}?
        true
      end
    LEVELS
  end

end



# This file was generated by the `rspec --init` command. Conventionally, all
# specs live under a `spec` directory, which RSpec adds to the `$LOAD_PATH`.
# Require this file using `require "spec_helper"` to ensure that it is only
# loaded once.
#
# See http://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
RSpec.configure do |config|
  # config.treat_symbols_as_metadata_keys_with_true_values = true
  config.run_all_when_everything_filtered = true
  config.filter_run :focus

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = 'random'

  unless (ENV.keys & ['SHOW_LOGGER_ALL', 'SHOW_LOGGER_ERRORS']).empty?
    config.instance_variable_set('@formatters', [])
    config.add_formatter(:documentation)
  end

  config.before(:suite) do
    cfg = Flapjack::Configuration.new
    $redis_options = cfg.load(FLAPJACK_CONFIG) ?
                     cfg.for_redis :
                     {:db => 14, :driver => :ruby}
  end

  config.around(:each, :redis => true) do |example|
    @redis = ::Redis.new($redis_options)
    @redis.flushdb
    example.run
    @redis.quit
  end

  config.around(:each, :logger => true) do |example|
    @logger = MockLogger.new
    example.run

    if ENV['SHOW_LOGGER_ALL']
      puts @logger.messages.compact.join("\n")
    end

    if ENV['SHOW_LOGGER_ERRORS']
      puts @logger.errors.compact.join("\n")
    end

    @logger.errors.clear
  end

  config.after(:each, :time => true) do
    Delorean.back_to_the_present
  end

  config.include ErbViewHelper, :erb_view => true
  config.include Rack::Test::Methods, :sinatra => true
  config.include AsyncRackTest::Methods, :sinatra => true
end
