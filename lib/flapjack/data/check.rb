#!/usr/bin/env ruby

require 'digest'

require 'sandstorm/records/redis_record'

require 'flapjack/data/check_state'
require 'flapjack/data/check_state_history'
require 'flapjack/data/contact'
require 'flapjack/data/scheduled_maintenance'
require 'flapjack/data/unscheduled_maintenance'

module Flapjack

  module Data

    class Check

      include Sandstorm::Records::RedisRecord

      # TODO include in Sandstorm::Records::Base
      include ActiveModel::Validations::Callbacks

      define_attributes :name                  => :string,
                        :state                 => :string,
                        :previous_state        => :string,
                        :perfdata_json         => :string,
                        :last_update           => :timestamp,
                        :last_problem_alert    => :timestamp,
                        :last_notification     => :timestamp,
                        :max_notified_severity => :string,
                        :enabled               => :boolean,
                        :ack_hash              => :string

      index_by :name, :enabled, :state
      unique_index_by :ack_hash

      belongs_to :entity, :class_name => 'Flapjack::Data::Entity', :inverse_of => :checks

      has_many :contacts, :class_name => 'Flapjack::Data::Contact'

      has_one :current_state, :class_name => 'Flapjack::Data::CheckState'
      has_one :state_history, :class_name => 'Flapjack::Data::CheckStateHistory'

      has_sorted_set :actions, :class_name => 'Flapjack::Data::Action', :key => :timestamp

      # keep two indices for each, so that we can query on their intersection
      has_sorted_set :scheduled_maintenances_by_start, :class_name => 'Flapjack::Data::ScheduledMaintenance',
        :key => :start_time
      has_sorted_set :scheduled_maintenances_by_end, :class_name => 'Flapjack::Data::ScheduledMaintenance',
        :key => :end_time

      has_sorted_set :unscheduled_maintenances_by_start, :class_name => 'Flapjack::Data::UnscheduledMaintenance',
        :key => :start_time
      has_sorted_set :unscheduled_maintenances_by_end, :class_name => 'Flapjack::Data::UnscheduledMaintenance',
        :key => :end_time

      has_sorted_set :notification_blocks, :class_name => 'Flapjack::Data::NotificationBlock',
        :key => :expire_at

      has_and_belongs_to_many :alerting_media, :class_name => 'Flapjack::Data::Medium',
        :inverse_of => :alerting_checks

      # the following 3 associations are used internally, for the notification
      # and alert queue inter-pikelet workflow
      has_many :notifications, :class_name => 'Flapjack::Data::Notification'
      has_many :alerts, :class_name => 'Flapjack::Data::Alert'
      has_many :rollup_alerts, :class_name => 'Flapjack::Data::RollupAlert'

      # TODO validate uniqueness of :name within entity

      validates :name, :presence => true
      validates :state,
        :inclusion => {:in => Flapjack::Data::CheckState.all_states, :allow_blank => true }

      before_validation :create_ack_hash
      validates :ack_hash, :presence => true

      # TODO handle JSON exception
      def perfdata
        if self.perfdata_json.nil?
          @perfdata = nil
          return
        end
        @perfdata ||= JSON.parse(self.perfdata_json)
      end

      # example perfdata: time=0.486630s;;;0.000000 size=909B;;;0
      def perfdata=(data)
        if data.nil?
          self.perfdata_json = nil
          return
        end

        data = data.strip
        if data.length == 0
          self.perfdata_json = nil
          return
        end
        # Could maybe be replaced by a fancy regex
        @perfdata = data.split(' ').inject([]) do |item|
          parts = item.split('=')
          memo << {"key"   => parts[0].to_s,
                   "value" => parts[1].nil? ? '' : parts[1].split(';')[0].to_s}
          memo
        end
        self.perfdata_json = @perfdata.nil? ? nil : @perfdata.to_json
      end

      def self.hash_by_entity_name(checks)
        checks.inject({}) {|memo, check|
          en = check.entity.name
          memo[en] = [] unless memo.has_key?(en)
          memo[en] << check
          memo
        }
      end

      # takes an array of ages (in seconds) to split all checks up by
      # - age means how long since the last update
      # - 0 age is implied if not explicitly passed
      # returns arrays of all current check names hashed by age range upper bound, eg:
      #
      # EntityCheck.find_all_split_by_freshness([60, 300], opts) =>
      #   {   0 => [ 'foo-app-01:SSH' ],
      #      60 => [ 'foo-app-01:Ping', 'foo-app-01:Disk / Utilisation' ],
      #     300 => [] }
      #
      # you can also set :counts to true in options and you'll just get the counts, eg:
      #
      # EntityCheck.find_all_split_by_freshness([60, 300], opts.merge(:counts => true)) =>
      #   {   0 => 1,
      #      60 => 3,
      #     300 => 0 }
      #
      # and you can get the last update time with each check too by passing :with_times => true eg:
      #
      # EntityCheck.find_all_split_by_freshness([60, 300], opts.merge(:with_times => true)) =>
      #   {   0 => [ ['foo-app-01:SSH', 1382329923.0] ],
      #      60 => [ ['foo-app-01:Ping', 1382329922.0], ['foo-app-01:Disk / Utilisation', 1382329921.0] ],
      #     300 => [] }
      #
      def self.split_by_freshness(ages, options = {})
        raise "ages does not respond_to? :each and :each_with_index" unless ages.respond_to?(:each) && ages.respond_to?(:each_with_index)
        raise "age values must respond_to? :to_i" unless ages.all? {|age| age.respond_to?(:to_i) }

        ages << 0
        ages = ages.sort.uniq

        start_time = Time.now

        # get all the current checks, with last update time

        current_checks = Flapjack::Data::Check.intersect(:enabled => true).all

        skeleton = ages.inject({}) {|memo, age| memo[age] = [] ; memo }
        age_ranges = ages.reverse.each_cons(2)
        results_with_times = current_checks.inject(skeleton) do |memo, check|
          check_age = start_time.to_i - check.last_update
          check_age = 0 unless check_age > 0
          if check_age >= ages.last
            memo[ages.last] << "#{check.entity.name}:#{check.name}"
          else
            age_range = age_ranges.detect {|a, b| check_age < a && check_age >= b }
            memo[age_range.last] << "#{check.entity.name}:#{check.name}" unless age_range.nil?
          end
          memo
        end

        case
        when options[:with_times]
          results_with_times
        when options[:counts]
          results_with_times.inject({}) do |memo, (age, check_names)|
            memo[age] = check_names.length
            memo
          end
        else
          results_with_times.inject({}) do |memo, (age, check_names)|
            memo[age] = check_names.map { |check_name| check_name }
            memo
          end
        end
      end

      def in_scheduled_maintenance?
        !scheduled_maintenance_ids_at(Time.now).empty?
      end

      def in_unscheduled_maintenance?
        !unscheduled_maintenance_ids_at(Time.now).empty?
      end

      def state_change(opts =  {})
        prev_state = self.state

        if opts.has_key?(:last_update) && !opts[:last_update].nil?
          if opts.has_key?(:state) && !opts[:state].nil?
            self.previous_state = self.state
            self.state = opts[:state]
          end
          self.last_update = opts[:last_update]
          self.enabled = true
        end

        enabling = self.changed.include?('enabled')

        self.save

        if enabling
          entity = self.entity

          if self.enabled
            entity.enabled = true
            entity.save
          else
            if entity.checks.intersect(:enabled => true).empty?
              entity.enabled = false
              entity.save
            end
          end
        end

        # TODO validation for: if state has changed, last_update must have changed
        return if opts[:last_update].nil? || !opts.has_key?(:state) ||
          (opts[:state] == prev_state)

        old_state = self.current_state

        unless old_state.nil?
          history = self.state_history.nil? ? Flapjack::Data::CheckStateHistory.new :
                                              self.state_history

          history.state     = old_state.state
          history.summaries = old_state.summaries
          history.details   = old_state.details
          history.notified  = old_state.notified
          history.save

          self.state_history = history if self.state_history.nil?
        end

        check_state = Flapjack::Data::CheckState.new(:state => opts[:state],
          :timestamp => opts[:last_update])
        check_state.save
        self.current_state = check_state

        old_state.destroy unless old_state.nil?
      end

      def add_scheduled_maintenance(sched_maint)
        self.scheduled_maintenances_by_start << sched_maint
        self.scheduled_maintenances_by_end << sched_maint
      end

      # TODO allow summary to be changed as part of the termination
      def end_scheduled_maintenance(sched_maint, at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        if sched_maint.start_time >= at_time
          # the scheduled maintenance period is in the future
          self.scheduled_maintenances_by_start.delete(sched_maint)
          self.scheduled_maintenances_by_end.delete(sched_maint)
          sched_maint.destroy
          return true
        end

        if sched_maint.end_time >= at_time
          # it spans the current time, so we'll stop it at that point
          # need to remove it from the sorted_set that uses the end_time as a key,
          # change and re-add -- see https://github.com/ali-graham/sandstorm/issues/1
          # TODO should this be in a multi/exec block?
          self.scheduled_maintenances_by_end.delete(sched_maint)
          sched_maint.end_time = at_time
          sched_maint.save
          self.scheduled_maintenances_by_end.add(sched_maint)
          return true
        end

        false
      end

      # def current_scheduled_maintenance
      def scheduled_maintenance_at(at_time)
        current_sched_ms = scheduled_maintenance_ids_at(at_time).map {|id|
          Flapjack::Data::ScheduledMaintenance.find_by_id(id)
        }
        return if current_sched_ms.empty?
        # if multiple scheduled maintenances found, find the end_time furthest in the future
        current_sched_ms.max_by(&:end_time)
      end

      def unscheduled_maintenance_at(at_time)
        current_unsched_ms = unscheduled_maintenance_ids_at(at_time).map {|id|
          Flapjack::Data::UnscheduledMaintenance.find_by_id(id)
        }
        return if current_unsched_ms.empty?
        # if multiple unscheduled maintenances found, find the end_time furthest in the future
        current_unsched_ms.max_by(&:end_time)
      end

      def set_unscheduled_maintenance(unsched_maint)
        current_time = Time.now

        # time_remaining
        if (unsched_maint.end_time - current_time) > 0
          self.clear_unscheduled_maintenance(unsched_maint.start_time)
        end

        self.unscheduled_maintenances_by_start << unsched_maint
        self.unscheduled_maintenances_by_end << unsched_maint
        self.last_update = current_time.to_i # ack is treated as changing state in this case
        self.save
      end

      def clear_unscheduled_maintenance(end_time)
        return unless unsched_maint = unscheduled_maintenance_at(Time.now)
        # need to remove it from the sorted_set that uses the end_time as a key,
        # change and re-add -- see https://github.com/ali-graham/sandstorm/issues/1
        # TODO should this be in a multi/exec block?
        self.unscheduled_maintenances_by_end.delete(unsched_maint)
        unsched_maint.end_time = end_time
        unsched_maint.save
        self.unscheduled_maintenances_by_end.add(unsched_maint)
      end

      # TODO statically store the correct answer, update when changing relevant values

      # def last_notification
      #   events = [self.unscheduled_maintenances_by_start.intersect(:notified => true).last,
      #             self.states.intersect(:notified => true).last].compact

      #   case events.size
      #   when 2
      #     events.max_by(&:last_notification_count)
      #   when 1
      #     events.first
      #   else
      #     nil
      #   end
      # end

      # def max_notified_severity_of_current_failure
      #   last_recovery = self.states.intersect(:notified => true, :state => 'ok').last
      #   last_recovery_time = last_recovery ? last_recovery.timestamp.to_i : 0

      #   states_since_last_recovery =
      #     self.states.intersect_range(last_recovery_time, nil, :by_score => true).
      #       collect(&:state).uniq

      #   ['critical', 'warning', 'unknown'].detect {|st| states_since_last_recovery.include?(st) }
      # end

      def tags
        @tags ||= Set.new(self.entity.name.split('.', 2).map(&:downcase) +
                          self.name.split(' ').map(&:downcase))
      end

      private

      # would need to be "#{self.entity.name}:#{name}" to be compatible with v1, but
      # to support name changes it must be something invariant
      def create_ack_hash
        return unless self.id.nil? # :on => :create isn't working
        self.id = self.class.generate_id
        self.ack_hash = Digest.hexencode(Digest::SHA1.new.digest(self.id))[0..7].downcase
      end

      def scheduled_maintenance_ids_at(at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        start_prior_ids = self.scheduled_maintenances_by_start.
          intersect_range(nil, at_time.to_i, :by_score => true).ids
        end_later_ids = self.scheduled_maintenances_by_end.
          intersect_range(at_time.to_i + 1, nil, :by_score => true).ids

        start_prior_ids & end_later_ids
      end

      def unscheduled_maintenance_ids_at(at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        start_prior_ids = self.unscheduled_maintenances_by_start.
          intersect_range(nil, at_time.to_i, :by_score => true).ids
        end_later_ids = self.unscheduled_maintenances_by_end.
          intersect_range(at_time.to_i + 1, nil, :by_score => true).ids

        start_prior_ids & end_later_ids
      end

      def create_history
        history = Flapjack::Data::CheckHistory.new
        history.save

        self.history = history
      end

    end

  end

end
