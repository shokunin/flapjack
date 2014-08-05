#!/usr/bin/env ruby

require 'sandstorm'

require 'flapjack/influxdb_proxy'
require 'flapjack/redis_proxy'

module Flapjack

  class << self

    {:redis    => Flapjack::RedisProxy,
     :influxdb => Flapjack::InfluxDBProxy}.each_pair do |backend, proxy_klass|

      # Thread and fiber-local
      define_method(backend) do
        cxn_name = "flapjack_#{backend}".to_sym
        cxn = Thread.current[cxn_name]
        return cxn unless cxn.nil?
        Thread.current[cxn_name] = proxy_klass.new
      end

    end

  end

end

