#!/usr/bin/env ruby

require 'chronic_duration'

require 'flapjack/redis_proxy'

require 'flapjack/filters/acknowledgement'
require 'flapjack/filters/ok'
require 'flapjack/filters/scheduled_maintenance'
require 'flapjack/filters/unscheduled_maintenance'
require 'flapjack/filters/delays'

require 'flapjack/data/action'
require 'flapjack/data/check'
require 'flapjack/data/notification'
require 'flapjack/data/event'
require 'flapjack/exceptions'
require 'flapjack/utility'

module Flapjack

  class Processor

    include Flapjack::Utility

    def initialize(opts = {})
      @lock = opts[:lock]

      @config = opts[:config]
      @logger = opts[:logger]

      @boot_time = opts[:boot_time]

      @queue = @config['queue'] || 'events'

      @notifier_queue = Flapjack::RecordQueue.new(@config['notifier_queue'] || 'notifications',
                 Flapjack::Data::Notification)

      # @archive_events        = @config['archive_events'] || false
      # @events_archive_maxage = @config['events_archive_maxage']

      ncsm_duration_conf = @config['new_check_scheduled_maintenance_duration'] || '100 years'
      @ncsm_duration = ChronicDuration.parse(ncsm_duration_conf, :keep_zero => true)

      @ncsm_ignore_tags = @config['new_check_scheduled_maintenance_ignore_tags'] || []

      @exit_on_queue_empty = !!@config['exit_on_queue_empty']

      filter_opts = {:logger => opts[:logger]}

      @filters = [Flapjack::Filters::Ok.new(filter_opts),
                  Flapjack::Filters::ScheduledMaintenance.new(filter_opts),
                  Flapjack::Filters::UnscheduledMaintenance.new(filter_opts),
                  Flapjack::Filters::Delays.new(filter_opts),
                  Flapjack::Filters::Acknowledgement.new(filter_opts)]

      fqdn          = `/bin/hostname -f`.chomp
      pid           = Process.pid
      @instance_id  = "#{fqdn}:#{pid}"
    end

    # expire instance keys after one week
    # TODO: set up a separate timer to reset key expiry every minute
    # and reduce the expiry to, say, five minutes
    # TODO: remove these keys on process exit
    def touch_keys
      Flapjack.redis.expire("executive_instance:#{@instance_id}", 1036800)
      Flapjack.redis.expire("event_counters:#{@instance_id}", 1036800)
    end

    def start
      @logger.info("Booting main loop.")

      begin
        Sandstorm.redis = Flapjack.redis

        # FIXME: add an administrative function to reset all event counters

        counter_types = ['all', 'ok', 'failure', 'action', 'invalid']
        counters = Hash[counter_types.zip(Flapjack.redis.hmget('event_counters', *counter_types))]

        Flapjack.redis.multi

        counter_types.select {|ct| counters[ct].nil? }.each do |counter_type|
          Flapjack.redis.hset('event_counters', counter_type, 0)
        end

        Flapjack.redis.zadd('executive_instances', @boot_time.to_i, @instance_id)
        Flapjack.redis.hset("executive_instance:#{@instance_id}", 'boot_time', @boot_time.to_i)
        Flapjack.redis.hmset("event_counters:#{@instance_id}",
                             'all', 0, 'ok', 0, 'failure', 0, 'action', 0, 'invalid', 0)
        touch_keys

        Flapjack.redis.exec

        queue = (@config['queue'] || 'events')

        loop do
          @lock.synchronize do
            foreach_on_queue(queue #,
                             # :archive_events => @archive_events,
                             # :events_archive_maxage => @events_archive_maxage
                             ) do |event|
              process_event(event)
            end
          end

          raise Flapjack::GlobalStop if @exit_on_queue_empty

          wait_for_queue(queue)
        end

      ensure
        Flapjack.redis.quit
      end
    end

    def stop_type
      :exception
    end

  private

    def foreach_on_queue(queue, opts = {})
      base_time_str = Time.now.utc.strftime "%Y%m%d%H"
      rejects = "events_rejected:#{base_time_str}"
      # archive = opts[:archive_events] ? "events_archive:#{base_time_str}" : nil
      # max_age = archive ? opts[:events_archive_maxage] : nil

      while event_json = (#archive ? Flapjack.redis.rpoplpush(queue, archive) :
                                    Flapjack.redis.rpop(queue))
        parsed = Flapjack::Data::Event.parse_and_validate(event_json, :logger => @logger)
        if parsed.nil?
          # if archive
          #   Flapjack.redis.multi
          #   Flapjack.redis.lrem(archive, 1, event_json)
          # end
          Flapjack.redis.lpush(rejects, event_json)
          Flapjack.redis.hincrby('event_counters', 'all', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'all', 1)
          Flapjack.redis.hincrby('event_counters', 'invalid', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'invalid', 1)
          # if archive
          #   Flapjack.redis.exec
          #   Flapjack.redis.expire(archive, max_age)
          # end
        else
          # Flapjack.redis.expire(archive, max_age) if archive
          yield Flapjack::Data::Event.new(parsed) if block_given?
        end
      end
    end

    def wait_for_queue(queue)
      Flapjack.redis.brpop("#{queue}_actions")
    end

    def process_event(event)
      pending = Flapjack::Data::Event.pending_count(@queue)
      @logger.debug("#{pending} events waiting on the queue")
      @logger.debug("Raw event received: #{event.inspect}")

      event_str = "#{event.id}, #{event.type}, #{event.state}, #{event.summary}"
      event_str << ", #{Time.at(event.time).to_s}" if event.time
      @logger.debug("Processing Event: #{event_str}")

      timestamp = Time.now.to_i

      entity_name, check_name = event.id.split(':', 2)

      entity = Flapjack::Data::Entity.intersect(:name => entity_name).all.first
      if entity.nil?
        entity = Flapjack::Data::Entity.new(:name => entity_name, :enabled => true)
        entity.save
      end

      check = entity.checks.intersect(:name => check_name).all.first
      if check.nil?
        check = Flapjack::Data::Check.new(:name => check_name)
        # not saving yet as check state isn't set, requires that for validation
        # TODO maybe change that?
      end

      should_notify, action = update_keys(event, check, timestamp)

      was_new_check = !check.persisted?
      check.save

      if @ncsm_sched_maint
        @ncsm_sched_maint.save
        check.add_scheduled_maintenance(@ncsm_sched_maint)
        @ncsm_sched_maint = nil
      end

      if was_new_check
        # action won't have been added to the check's actions set yet
        check.actions << action
        # created a new check, so add it to the entity's check list
        entity.checks << check
      end

      if !should_notify
        @logger.debug("Not generating notification for event #{event.id} because filtering was skipped")
        return
      elsif blocker = @filters.find {|filter| filter.block?(event, check) }
        @logger.debug("Not generating notification for event #{event.id} because this filter blocked: #{blocker.name}")
        return
      end

      @logger.info("Generating notification for event #{event_str}")
      generate_notification(event, check, timestamp)
    end

    def update_keys(event, check, timestamp)
      touch_keys

      result = true

      event.counter = Flapjack.redis.hincrby('event_counters', 'all', 1)
      Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'all', 1)

      # FIXME: validate that the event is sane before we ever get here
      # FIXME: create an event if there is dodgy data

      case event.type
      # Service events represent current state of checks on monitored systems
      when 'service'
        Flapjack.redis.multi
        if Flapjack::Data::CheckState.ok_states.include?( event.state )
          Flapjack.redis.hincrby('event_counters', 'ok', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'ok', 1)
        elsif Flapjack::Data::CheckState.failing_states.include?( event.state )
          Flapjack.redis.hincrby('event_counters', 'failure', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'failure', 1)
          event.id_hash = check.ack_hash
        else
          Flapjack.redis.hincrby('event_counters', 'invalid', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'invalid', 1)
          @logger.error("Invalid event received: #{event.inspect}")
        end
        Flapjack.redis.exec

        if check.state.nil?
          @logger.info("No previous state for event #{event.id}")

          if (@ncsm_duration > 0) && ((event.tags || []) & @ncsm_ignore_tags).empty?
            @logger.info("Setting scheduled maintenance for #{time_period_in_words(@ncsm_duration)}")

            @ncsm_sched_maint = Flapjack::Data::ScheduledMaintenance.new(:start_time => timestamp,
              :end_time => timestamp + @ncsm_duration,
              :summary => 'Automatically created for new check')
          end

          # If the service event's state is ok and there was no previous state, don't alert.
          # This stops new checks from alerting as "recovery" after they have been added.
          if Flapjack::Data::CheckState.ok_states.include?( event.state )
            @logger.debug("setting skip_filters to true because there was no previous state and event is ok")
            result = false
          end
        end

        # TODO rename 'last_update' here
        check.state_change(:state => event.state, :summary => event.summary,
          :details => event.details, :perfdata => event.perfdata,
          :last_update => timestamp)

      # Action events represent human or automated interaction with Flapjack
      when 'action'
        action = Flapjack::Data::Action.new(:action => event.state,
          :timestamp => timestamp)
        action.save
        check.actions << action if check.persisted?

        Flapjack.redis.multi
        Flapjack.redis.hincrby('event_counters', 'action', 1)
        Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'action', 1)
        Flapjack.redis.exec
      else
        Flapjack.redis.multi
        Flapjack.redis.hincrby('event_counters', 'invalid', 1)
        Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'invalid', 1)
        Flapjack.redis.exec
        @logger.error("Invalid event received: #{event.inspect}")
      end

      [result, action]
    end

    def generate_notification(event, check, timestamp)
      current_state = check.current_state

      # TODO should probably look these up by 'timestamp', last may not be safe...
      case event.type
      when 'service'

        @logger.debug("previous max severity: #{check.max_notified_severity}")

        if Flapjack::Data::CheckState.failing_states.include?( event.state )
          check.last_problem_alert = timestamp

          case check.max_notified_severity
          when nil
            check.max_notified_severity = event.state
          when 'unknown'
            check.max_notified_severity = event.state if ['warning', 'critical'].include?(event.state)
          when 'warning'
            check.max_notified_severity = event.state if 'critical'.eql?(event.state)
          end
          severity = check.max_notified_severity
        else
          severity = ['critical', 'warning', 'unknown', 'ok'].detect {|st|
            [event.state, check.max_notified_severity].include?(st)
          }
          check.max_notified_severity = nil
        end

        @logger.debug("current max severity: #{check.max_notified_severity}")

        check.last_notification = timestamp
        check.save

        current_state.notified = true
        current_state.last_notification_count = event.counter
        current_state.save
      when 'action'
        if event.state == 'acknowledgement'
          severity = ['critical', 'warning', 'unknown', 'ok'].detect {|st|
            [event.state, check.max_notified_severity].include?(st)
          }

          check.last_notification = timestamp
          check.save

          unsched_maint = check.unscheduled_maintenances_by_start.last
          unsched_maint.notified = true
          unsched_maint.last_notification_count = event.counter
          unsched_maint.save
        elsif event.state == 'test_notifications'
          severity = 'critical'
        end
      end

      @logger.debug("Notification is being generated for #{event.id}: " + event.inspect)

      notification = Flapjack::Data::Notification.new(
        :state             => event.state,
        :state_duration    => (current_state ? (timestamp - current_state.timestamp.to_i) : nil),
        :severity          => severity,
        :type              => event.notification_type,
        :time              => event.time,
        :duration          => event.duration,
        :tags              => check.tags,
      )

      notification.save

      check.notifications << notification
      # current_state.current_notifications << notification unless current_state.nil?
      # previous_state.previous_notifications << notification unless previous_state.nil?

      @notifier_queue.push(notification)
    end

  end
end

