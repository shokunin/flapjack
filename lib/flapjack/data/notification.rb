#!/usr/bin/env ruby

# 'Notification' refers to the template object created when an event occurs,
# from which individual 'Message' objects are created, one for each
# contact+media recipient.

require 'sandstorm/records/redis_record'

require 'flapjack/data/alert'
require 'flapjack/data/contact'

module Flapjack
  module Data
    class Notification

      include Sandstorm::Records::RedisRecord

      attr_accessor :logger

      define_attributes :state          => :string,
                        :state_duration => :integer,
                        :severity       => :string,
                        :type           => :string,
                        :time           => :timestamp,
                        :duration       => :integer,
                        :tags           => :set,
                        :event_hash     => :string

      belongs_to :check, :class_name => 'Flapjack::Data::Check',
        :inverse_of => :notifications

      # TODO validate state in acceptable set
      validate :state, :presence => true
      validate :state_duration, :presence => true
      validate :severity, :presence => true
      validate :type, :presence => true
      validate :time, :presence => true
      validate :event_hash, :presence => true

      # TODO ensure 'unacknowledged_failures' behaviour is covered

      def state_or_ack
        case self.type
        when 'acknowledgement', 'test'
          self.type
        else
          self.state
        end
      end

      def alerts(contacts, opts = {})
        @logger = opts[:logger]

        return [] if contacts.nil? || contacts.empty?

        default_timezone = opts[:default_timezone]

        alert_check = self.check

        contacts.inject([]) do |memo, contact|

          matchers = matching_rules_for_contact(contact, :check => alert_check,
            :default_timezone => default_timezone)

          next memo if matchers.nil?

          media_to_use = media_for_contact(contact, matchers, :check => alert_check)

          next memo if media_to_use.empty?

          media_to_use.each do |medium|
            alert = alert_for_medium(medium, :check => alert_check)
            next if alert.nil?
            memo << alert
          end

          memo
        end
      end

      def log_rules(rules, description)
        return if logger.nil?
        logger.debug "#{rules.count} matching rules remain after #{description}:"
        rules.each do |rule|
          logger.debug "  - #{rule.inspect}"
          # rule.states.each do |rule_state|
          #   logger.debug "  - #{rule_state.inspect}"
          # end
        end
      end

      def matching_rules_for_contact(contact, options = {})
        rules = contact.notification_rules

        check = options[:check]
        entity_name = check.entity.name

        log_rules(rules, "initial")

        matchers = rules.select do |rule|
          (!rule.is_specific? ||
           (rule.match_tags?(self.tags) && rule.match_regex_tags?(self.tags) &&
            rule.match_entity?(entity_name) && rule.match_regex_entities?(entity_name))) &&
          rule.is_occurring_now?(:contact => contact,
            :default_timezone => options[:default_timezone])
        end

        log_rules(matchers, "after time, entity and tags") if matchers.count != rules.count

        # delete any general matchers if there are more specific matchers left
        if matchers.any? {|matcher| matcher.is_specific? }
          num_matchers = matchers.count
          matchers.reject! {|matcher| !matcher.is_specific? }

          log_rules(matchers, "after remove general if specific exist") if matchers.count != rules.count
        end

        # delete media based on blackholes
        blackhole_matchers = matchers.inject([]) {|memo, matcher|
          if matcher.states.intersect(:state => self.severity, :blackhole => true).count > 0
            memo << matcher
          end
          memo
        }

        if blackhole_matchers.length > 0
          log_rules(blackhole_matchers, "#{blackhole_matchers.count} blackhole matchers found - skipping")
          return
        elsif !logger.nil?
          logger.debug "no blackhole matchers matched"
        end

        matchers
      end

      # return value may or may not be a Sandstorm association; i.e. collect,
      # each, etc. methods may be used on its contained values. if nil is
      # returned that value will be compacted away.
      def media_for_contact(contact, matchers, opts = {})
        contact_id = contact.id
        media = contact.media

        return media if matchers.empty?

        check = opts[:check]

        matcher_states = matchers.collect {|m|
          m.states.intersect(:state => self.severity).all
        }.flatten

        rule_media = matcher_states.inject({}) do |memo, nr_state|
          nr_state_media = nr_state.media.reject {|m| memo.has_key?(m.type) }
          nr_state_media.each do |nrsm|
            memo[nrsm.type] = nrsm
          end
          memo
        end.values

        unless logger.nil?
          logger.debug "collected media_for_severity(#{self.severity}): #{rule_media.inspect}"
        end

        final_media = rule_media.reject {|medium|
          medium.drop_notifications?(:check => check,
                                     :state => state_or_ack)
        }

        unless logger.nil?
          logger.debug "media after contact_drop?: #{final_media.collect(&:type)}"
        end

        final_media
      end

      def alert_for_medium(medium, opts = {})
        rollup_type = nil
        media_type  = medium.type

        unless logger.nil?
          logger.debug("using media #{media_type}")
        end

        alert_check = opts[:check]
        entity_name = check.entity.name
        check_name = check.name

        unless (['ok', 'acknowledgement', 'test'].include?(state_or_ack)) ||
          medium.alerting_checks.exists?(alert_check.id)

          medium.alerting_checks << alert_check
        end

        # expunge checks in (un)scheduled maintenance from the alerting set
        cleaned = medium.clean_alerting_checks
        unless logger.nil?
          logger.debug("cleaned alerting checks for #{media_type}: #{cleaned}")
        end

        alerting_checks_count = medium.alerting_checks.count
        unless logger.nil?
          logger.debug("current alerting checks for #{media_type}: #{alerting_checks_count}")
        end

        unless medium.rollup_threshold.nil?
          if alerting_checks_count >= medium.rollup_threshold
            if medium.drop_notifications?(:rollup => true)
              unless logger.nil?
                logger.debug("dropping notifications as medium blocked")
              end
              return
            end

            medium.update_sent_alert_keys(:rollup => true,
              :delete => (['ok', 'acknowledgement'].include?(state_or_ack)))
            rollup_type = 'problem'
          elsif (alerting_checks_count + cleaned) >= medium.rollup_threshold
            # alerting checks was just cleaned such that it is now below the rollup threshold
            rollup_type = 'recovery'
          end
        end

        unless logger.nil?
          logger.debug "rollup decisions: #{entity_name}:#{check_name} " +
            "#{state_or_ack} #{media_type} #{medium.address} " +
            "rollup_type: #{rollup_type}"
        end

        alert = Flapjack::Data::Alert.new(:state => self.state_or_ack,
          :rollup => rollup_type, :state_duration => self.state_duration,
          :acknowledgement_duration => duration,
          :notification_type => self.type)
        unless alert.save
          raise "Couldn't save alert: #{alert.errors.full_messages.inspect}"
        end

        medium.alerts << alert
        alert_check.alerts << alert

        alert
      end

    end
  end
end
