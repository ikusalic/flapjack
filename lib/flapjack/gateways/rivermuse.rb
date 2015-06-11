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

        if @config.nil? || (@config.respond_to?(:empty?) && @config.empty?)
          @logger.error "Rivermuse config is missing"
          return
        end

        @endpoint = @config['endpoint']
        if @endpoint.nil? || (@endpoint.respond_to?(:empty?) && @endpoint.empty?)
          @logger.error "Rivermuse endpoint is missing"
          return
        end
        @notification_interval = @config['notification_interval_in_seconds'] || 60

        contact_id = @config['contact_id']
        if contact_id.nil? || (contact_id.respond_to?(:empty?) && contact_id.empty?)
          @logger.error "Rivermuse contact id is missing"
          return
        else
          @contact = find_or_crate_contact(contact_id)
        end

        attach_all_entities_to_contact()

        @source_type = @config['source_type']
        if @source_type.nil? || (@source_type.respond_to?(:empty?) && @source_type.empty?)
          @logger.error "Rivermuse source type is missing"
          return
        end

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
        rivermuse_event = alert_to_rivermuse_event(alert)

        events_data = "[#{rivermuse_event.to_json}]"
        encoded_events="events=#{escape(events_data)}"
        headers = {'content-type' => 'application/json'}
        http = EM::HttpRequest.new(@endpoint).post(:head => headers, :body => encoded_events)

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
            'source'   => @source_type,
            'source_instance' => 'SDP'  # TODO
          }
        rescue
          puts "Failed to collect necessary Rivermuse event data from alert: #{alert}"
        end

        def find_or_crate_contact(contact_id)
          if Flapjack::Data::Contact.exists_with_id?(contact_id, :redis => @redis)
            contact = Flapjack::Data::Contact.find_by_id(contact_id, :redis => @redis)
            @logger.info "Found Rivermuse contact: #{contact}"
          else
            @logger.debug "Creating Rivermuse contact."
            contact = Flapjack::Data::Contact.add( {
                'id'         => contact_id,
                'first_name' => 'Rivermuse',
                'last_name'  => 'Contact',
                'media'      => {
                  'rivermuse' => { 'endpoint' => @endpoint },
                },
              },
              :redis => @redis)
            @logger.debug "Created Rivermuse contact: #{contact}"

            @logger.debug "Removing existing notification rules for Rivermuse contact."
            contact.notification_rules.each { |nr| contact.delete_notification_rule(nr) }

            @logger.debug "Creating notification rule."
            rule = contact.add_notification_rule(
              {
                :entities           => [],
                :regex_entities     => [],
                :tags               => Set.new([]),
                :regex_tags         => Set.new([]),
                :time_restrictions  => [],
                :warning_media      => ['rivermuse'],
                :critical_media     => ['rivermuse'],
                :warning_blackhole  => false,
                :critical_blackhole => false,
              }, :logger => @logger
            )
            @logger.debug "Added notification rule for Rivermuse contact: #{rule}"

            @logger.debug "Setting rivermuse interval #{@notification_interval} for Rivermuse contact."
            contact.set_interval_for_media('rivermuse', @notification_interval)

            @logger.info "Created Rivermuse contact: #{contact}"
          end

          contact
        end

        def attach_all_entities_to_contact()
          Flapjack::Data::Entity.all(:redis => @redis).each do |entity|
            @contact.add_entity(entity)
          end

          reason = "Automatically created for new check"
          Flapjack::Data::EntityCheck.delete_maintenance(:redis => @redis, :reason => reason, :type => "scheduled")
        end

    end
  end
end

