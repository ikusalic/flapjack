#!/usr/bin/env ruby

require 'em-synchrony'
require 'em-synchrony/em-http'
require 'active_support/inflector'

require 'flapjack/redis_pool'

require 'flapjack/data/alert'
require 'flapjack/utility'

module Flapjack

  module Gateways

    class Rivermuse

      include Flapjack::Utility

      include EM::HttpEncoding

      SEVERITY_MAPPING = { 'ok' => 'CLEAR', 'warning' => 'WARNING', 'critical' => 'CRITICAL' }
      UNKNOWN_SEVERITY = 'WARNING'

      def initialize(opts = {})
        @config = opts[:config]
        @logger = opts[:logger]
        @redis_config = opts[:redis_config] || {}
        @redis = Flapjack::RedisPool.new(:config => @redis_config, :size => 1, :logger => @logger)

        @logger.info("starting")
        @logger.debug("new rivermuse gateway pikelet with the following options: #{@config.inspect}")

        @sent = 0
      end

      def stop
        @logger.info("stopping")
        @should_quit = true

        redis_uri = @redis_config[:path] ||
          "redis://#{@redis_config[:host] || '127.0.0.1'}:#{@redis_config[:port] || '6379'}/#{@redis_config[:db] || '0'}"
        shutdown_redis = EM::Hiredis.connect(redis_uri)
        shutdown_redis.rpush(@config['queue'], Flapjack.dump_json('notification_type' => 'shutdown'))
      end

      def start
        queue = @config['queue']

        until @should_quit
          begin
            @logger.debug("rivermuse gateway is going into blpop mode on #{queue}")
            alert = Flapjack::Data::Alert.next(queue, :redis => @redis, :logger => @logger)
            deliver(alert) unless alert.nil?
          rescue => e
            @logger.error "Error generating or dispatching Rivermuse event: #{e.class}: #{e.message}\n" +
              e.backtrace.join("\n")
          end
        end
      end

      def deliver(alert)
        if @config.nil? || (@config.respond_to?(:empty?) && @config.empty?)
          @logger.error "Rivermuse config is missing"
          return
        end
        default_endpoint = @config['default_endpoint']
        if default_endpoint.nil? || (default_endpoint.respond_to?(:empty?) && default_endpoint.empty?)
          @logger.error "Rivermuse default endpoint config value is missing"
          return
        end

        endpoint = default_endpoint  # TODO

        rivermuse_event = alert_to_rivermuse_event(alert)

        events_data = "[#{rivermuse_event.to_json}]"
        encoded_events="events=#{escape(events_data)}"
        headers = {'content-type' => 'application/json'}
        http = EM::HttpRequest.new(endpoint).post(:head => headers, :body => encoded_events)

        @logger.debug "server response: #{http.response}"

        status = (http.nil? || http.response_header.nil?) ? nil : http.response_header.status
        if (status >= 200) && (status <= 206)
          @sent += 1
          alert.record_send_success!
          @logger.debug "Sent notification via Rivermuse, response status is #{status}, " +
            "notification_id: #{alert.notification_id}"
        else
          @logger.error "Failed to send notification via Rivermuse, response status is #{status}, " +
            "notification_id: #{alert.notification_id}"
        end
      rescue => e
        @logger.error "Error generating or delivering notification to #{address}: #{e.class}: #{e.message}"
        @logger.error e.backtrace.join("\n")
        raise
      end

    private

        def alert_to_rivermuse_event(alert)
          message = "#{alert.summary}\n\n#{alert.details}"
          severity = SEVERITY_MAPPING[alert.state.downcase] || UNKNOWN_SEVERITY
          {
            'type'     => 'EVENT',
            'entity'   => alert.entity,
            'service'  => alert.check,
            'severity' => severity,
            'message'  => message,
            'source'   => 'AWS',  # TODO config
            'source_instance' => 'SDP'  # TODO
          }
        rescue
          puts "Failed to collect necessary Rivermuse event data from alert: #{alert}"
        end

    end
  end
end

