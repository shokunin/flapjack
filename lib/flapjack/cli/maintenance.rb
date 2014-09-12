#!/usr/bin/env ruby

require 'redis'

require 'flapjack/configuration'
require 'flapjack/data/event'
require 'flapjack/data/check'
require 'terminal-table'

module Flapjack
  module CLI
    class Maintenance

      def initialize(global_options, options)
        @global_options = global_options
        @options = options

        config = Flapjack::Configuration.new
        config.load(global_options[:config])
        @config_env = config.all

        if @config_env.nil? || @config_env.empty?
          exit_now! "No config data for environment '#{FLAPJACK_ENV}' found in '#{global_options[:config]}'"
        end

        Flapjack::RedisProxy.config = config.for_redis
        Sandstorm.redis = Flapjack.redis
      end

      def show(base_time = Time.now)
        entities = if @options[:entity]
          Flapjack::Data::Entity.intersect(:name => Regexp.new(@options[:entity])).all
        else
          Flapjack::Data::Entity.all
        end

        state = @options[:state]

        checks = if @options[:check]
          check_ids = Flapjack::Data::Check.intersect(:name => Regexp.new(@options[:check])).ids

          if check_ids.empty?
            []
          else
            entities.inject([]) do |memo, entity|
              ch = entity.checks.find_by_ids(check_ids).compact
              memo += ch unless ch.empty? || (state && (ch.state != state))
              memo
            end
          end
        else
          entities.inject([]) do |memo, entity|
            ch = entity.checks.all
            memo += ch unless ch.empty? || (state && (ch.state != state))
            memo
          end
        end

        start_time_begin, start_time_end = self.class.extract_time_range(
          @options[:started], base_time)

        start_time_begin = start_time_begin.to_i unless start_time_begin.nil?
        start_time_end = start_time_end.to_i unless start_time_end.nil?

        finish_time_begin, finish_time_end = self.class.extract_time_range(
          @options[:finishing], base_time)

        finish_time_begin = finish_time_begin.to_i unless finish_time_begin.nil?
        finish_time_end = finish_time_end.to_i unless finish_time_end.nil?

        duration_range = @options[:duration] ? self.class.extract_duration_range(
          @options[:duration]) : nil

        maintenances = case @options[:type].downcase
        when 'scheduled'
          checks.inject([]) do |memo, check|
            start_ids = check.scheduled_maintenances_by_start.
              intersect_range(start_time_begin, start_time_end, :by_score => true).ids

            end_ids = check.scheduled_maintenances_by_end.
              intersect_range(finish_time_begin, finish_time_end, :by_score => true).ids

            included_ids = start_ids & end_ids

            unless included_ids.empty?
              maints   = Flapjack::Data::ScheduledMaintenance.find_by_ids(*included_ids)

              if !maints.empty?
                filtered = duration_range.nil? ? maints :
                  self.class.filter_duration(maints, duration_range)
                memo += filtered
              end
            end

            memo
          end
        when 'unscheduled'
          checks.inject([]) do |memo, check|
            start_ids = check.unscheduled_maintenances_by_start.
              intersect_range(start_time_begin, start_time_end, :by_score => true).ids

            end_ids = check.scheduled_maintenances_by_end.
              intersect_range(finish_time_begin, finish_time_end, :by_score => true).ids

            included_ids = start_ids & end_ids

            unless included_ids.empty?
              maints   = Flapjack::Data::UnscheduledMaintenance.find_by_ids(*included_ids)

              if !maints.empty?
                filtered = duration_range.nil? ? maints :
                  self.class.filter_duration(maints, duration_range)
                memo += filtered
              end
            end

            memo
          end
        end

        rows = maintenances.collect do |maint|
          check = maint.check_by_start
          [check.entity.name, check.name, check.state,
           Time.at(maint.start_time), maint.end_time - maint.start_time,
           maint.summary, Time.at(maint.end_time)]
        end
        puts Terminal::Table.new :headings => ['Entity', 'Check', 'State',
          'Start', 'Duration (s)', 'Reason', 'End'], :rows => rows
        maintenances
      end

      def delete
        base_time = Time.now

        maintenances = show(base_time)

        unless @options[:apply]
          exit_now!('The following maintenances would be deleted. Run this ' +
            'command again with --apply true to remove them.')
        end

        errors = {}
        maintenances.each do |maint|
          check = maint.check_by_start
          identifier = "#{check.entity.name}:#{check.name}:#{check.start}"
          if maint.end_time < base_time
            errors[identifier] = "Maintenance can't be deleted as it finished in the past"
          else
            success = case @options[:type]
            when 'scheduled'
              check.end_scheduled_maintenance(check.start_time)
            when 'unscheduled'
              check.end_unscheduled_maintenance(check.start_time)
            end
            errors[identifier] = "The following maintenance failed to delete: #{entry}" unless success
          end
        end

        if errors.empty?
          puts "The maintenances above have been deleted"
        else
          puts(errors.map {|k, v| "#{k}: #{v}" }.join("\n"))
          exit_now!('Failed to delete maintenances')
        end
      end

      def create
        errors = {}

        entity_names = @options[:entity].is_a?(String) ? @options[:entity].split(',') : @options[:entity]
        check_names  = @options[:check].is_a?(String) ? @options[:check].split(',') : @options[:check]

        started = Chronic.parse(options[:started])
        raise "Failed to parse start time #{@options[:started]}" if started.nil?

        duration = ChronicDuration.parse(@options[:duration])
        raise "Failed to parse duration #{@options[:duration]}" if duration.nil?

        entity_names.each do |entity_name|
          entity = Flapjack::Data::Entity.intersect(:name => entity_name).all.first

          if entity.nil?
            # Create the entity if it doesn't exist, so we can schedule maintenance against it
            entity = Flapjack::Data::Entity.new(:name => entity_name)
            entity.save
          end

          check_names.each do |check_name|
            check = Flapjack::Data::Check.intersect(:name => check_name).all.first

            if check.nil?
              # Create the check if it doesn't exist, so we can schedule maintenance against it
              check = Flapjack::Data::Check.new(:name => check_name)
              check.save
              entity.checks << check
            end

            success = case @options[:type]
            when 'scheduled'

              sched_maint = Flapjack::Data::ScheduledMaintenance.new(:start_time => started,
                :end_time => started + duration, :summary => @options[:reason])
              sched_maint.save

              check.add_scheduled_maintenance(sched_maint)
            when 'unscheduled'
              unsched_maint = Flapjack::Data::UnscheduledMaintenance.new(:start_time => started,
                :end_time => started + duration, :summary => @options[:reason])
              unsched_maint.save

              check.set_unscheduled_maintenance(unsched_maint)
            end
            identifier = "#{entity_name}:#{check_name}:#{started}"
            errors[identifier] = "The following check failed to create: #{identifier}" unless success
          end
        end

        if errors.empty?
          puts "The maintenances specified have been created"
        else
          puts(errors.map {|k, v| "#{k}: #{v}" }.join("\n"))
          exit_now!('Failed to create maintenances')
        end
      end

      private

      def self.filter_duration(maints, duration_range)
        maints.select do |maint|
          dur = maint.duration
          lower = duration_range.first
          upper = duration_range.last

          (lower.nil? && upper.nil?) || ((lower.nil? || (dur >= lower)) &&
                                         (upper.nil? || (dur <  upper)))
        end
      end

      def self.extract_duration_range(duration_in_words)
        return nil if duration_in_words.nil?

        dur_words = duration_in_words.downcase

        case dur_words
        when /^(?:equal to|less than|more than)/
          cdur_words = dur_words.gsub(/^(equal to|less than|more than) /, '')
          parsed_dur = ChronicDuration.parse(cdur_words)
          case dur_words
          when /^equal to/
            [parsed_dur, parsed_dur + 1]
          when /^less than/
            [nil, parsed_dur]
          when /^more than/
            [parsed_dur, nil]
          end
        when /^between/
          first, second = dur_words.match(/between (.*) and (.*)/).captures

          # If the first time only contains only a single word, the unit (and past/future) is
          # most likely directly after the first word of the the second time
          # eg between 3 and 4 hours
          suffix = second.match(/\w (.*)/) ? second.match(/\w (.*)/).captures.first : ''
          first = "#{first} #{suffix}" unless / /.match(first)

          [ChronicDuration.parse(first), ChronicDuration.parse(second)].sort
        end
      end

      # returns two timestamps, the start and end of the calculated time range. if
      # either one is nil that indicates that the range is unbounded at that end.
      # Start is inclusive of that second, end is exclusive.
      def self.extract_time_range(time_period_in_words, base_time)
        return nil if time_period_in_words.nil?

        time_words = time_period_in_words.downcase

        # Chronic can't parse timestamps for strings starting with before, after or in some cases, on.
        # Strip the before or after for the conversion only, but use it for the comparison later
        ctime_words = time_words.gsub(/^(on|before|after) /, '')

        case time_words
        # Between 3 and 4 hours ago translates to more than 3 hours ago, less than 4 hours ago
        when /^between/
          first, second = time_words.match(/between (.*) and (.*)/).captures

          # If the first time only contains only a single word, the unit (and past/future) is
          # most likely directly after the first word of the the second time
          # eg between 3 and 4 hours ago
          suffix = second.match(/\w (.*)/) ? second.match(/\w (.*)/).captures.first : ''
          first = "#{first} #{suffix}" unless / /.match(first)

          [Chronic.parse(first,  :now => base_time),
           Chronic.parse(second, :now => base_time)].sort
        when /^on/
          # e.g. On 1/1/15.  We use Chronic to work out the minimum and maximum timestamp.
          parsed = Chronic.parse(ctime, :guess => false, :now => base_time)
          [parsed.first, parsed.last]
        when /^(less than|more than|before|after)/
          input_time = Chronic.parse(ctime_words, :keep_zero => true, :now => base_time) ||
            Chronic.parse("#{ctime_words} from now", :keep_zero => true, :now => base_time)
          case time_words
          when /^less than .+ ago$/, /^more than/, /^after/
            [input_time, nil]
          when /^less than/, /^more than .+ ago$/, /^before/
            [nil, input_time]
          end
        end
      end

    end
  end
end

def common_arguments(cmd_type, gli_cmd)

  if [:show, :delete, :create].include?(cmd_type)
    gli_cmd.flag [:e, 'entity'],
      :desc => 'The entity for the maintenance window to occur on. This can ' +
        ' be a string, or a Ruby regex of the form \'db*\' or \'[[:lower:]]\'',
        :required => :create.eql?(cmd_type)

    gli_cmd.flag [:c, 'check'],
      :desc => 'The check for the maintenance window to occur on. This can ' +
        'be a string, or a Ruby regex of the form \'http*\' or \'[[:lower:]]\'',
      :required => :create.eql?(cmd_type)

    gli_cmd.flag [:r, 'reason'],
      :desc => 'The reason for the maintenance window to occur. This can ' +
        'be a string, or a Ruby regex of the form \'Downtime for *\' or ' +
        '\'[[:lower:]]\''

    gli_cmd.flag [:s, 'start', 'started', 'starting'],
      :desc => 'The start time for the maintenance window. This should ' +
               'be prefixed with "more than", "less than", "on", "before", ' +
               'or "after", or of the form "between T1 and T2"',
      :must_match => /^(?:more than|less than|on|before|after|between)\s+.+$/

    gli_cmd.flag [:d, 'duration'],
      :desc => 'The total duration of the maintenance window. This should ' +
               'be prefixed with "more than", "less than", or "equal to", ' +
               'or of the form "between M and N hours". This should be an ' +
               ' interval',
      :must_match => /^(?:more than|less than|equal to|between)\s+.+$/
  end

  if [:show, :delete].include?(cmd_type)
    gli_cmd.flag [:f, 'finish', 'finished', 'finishing', 'remain', 'remained', 'remaining', 'end'],
      :desc => 'The finishing time for the maintenance window. This should ' +
               'prefixed with "more than", "less than", "on", "before", or ' +
               '"after", or of the form "between T1 and T2"' ,
      :must_match => /^(?:more than|less than|on|before|after|between)\s+.+$/

    gli_cmd.flag [:st, 'state'],
      :desc => 'The state that the check is currently in',
      :must_match => %w(ok warning critical unknown)
  end

  if [:show, :delete, :create].include?(cmd_type)
    gli_cmd.flag [:t, 'type'],
      :desc          => 'The type of maintenance scheduled',
      :required      => true,
      :default_value => 'scheduled',
      :must_match    => %w(scheduled unscheduled)
  end

end

desc 'Show, create and delete maintenance windows'
command :maintenance do |maintenance|

  maintenance.desc 'Show maintenance windows according to criteria (default: all ongoing maintenance)'
  maintenance.command :show do |show|

    common_arguments(:show, show)

    show.action do |global_options,options,args|
      maintenance = Flapjack::CLI::Maintenance.new(global_options, options)
      maintenance.show
    end
  end

  maintenance.desc 'Delete maintenance windows according to criteria (default: all ongoing maintenance)'
  maintenance.command :delete do |delete|

    delete.flag [:a, 'apply'],
      :desc => 'Whether this deletion should occur',
      :default_value => false

    common_arguments(:delete, delete)

    delete.action do |global_options,options,args|
      maintenance = Flapjack::CLI::Maintenance.new(global_options, options)
      maintenance.delete
    end
  end

  maintenance.desc 'Create a maintenance window'
  maintenance.command :create do |create|

    common_arguments(:create, create)

    create.action do |global_options,options,args|
      maintenance = Flapjack::CLI::Maintenance.new(global_options, options)
      maintenance.create
    end
  end
end
