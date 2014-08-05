#!/usr/bin/env ruby

# defer initialisation for InfluxDB connections until they're used.
require 'influxdb'

module Flapjack

  class InfluxDBProxy

    class << self
      attr_accessor :config
    end

    def quit
      return if @proxied_connection.nil?
      @proxied_connection.quit
    end

    def method_missing(name, *args, &block)
      proxied_connection.send(name, *args, &block)
    end

    private

    def proxied_connection
      @proxied_connection ||= ::InfluxDB::Client.new(self.class.config['database'],
        :username => self.class.config['username'],
        :password => self.class.config['password'])
    end

  end

end
