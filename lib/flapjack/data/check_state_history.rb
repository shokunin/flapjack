#!/usr/bin/env ruby

require 'sandstorm/records/influxdb_record'

module Flapjack

  module Data

    class CheckStateHistory

      # as details are changed and saved, it creates a new entry in the
      # relevant time series
      include Sandstorm::Records::InfluxDBRecord

      belongs_to :check, :class_name => 'Flapjack::Data::Check', :inverse_of => :state_history

      define_attributes :state     => :string,
                        :summaries => :list,
                        :details   => :list,
                        :timestamp => :timestamp,
                        :notified  => :boolean

    end

  end

end