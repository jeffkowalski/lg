#!/usr/bin/env ruby
# frozen_string_literal: true

# HACK: use local config to downgrade ssl version to accomodate LG server
ENV['OPENSSL_CONF'] = 'openssl.cnf'

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class LG < RecorderBotBase
  ##
  # Interactively authorize the application
  desc 'authorize', '[re]authorize the application'
  def authorize
    client = WIDEQ::Client.load({})
    gateway = client.gateway
    login_url = gateway.oauth_url
    puts 'Log in here:'
    puts login_url
    puts 'Then paste the URL where the browser is redirected:'
    callback_url = $stdin.gets.chomp
    client._auth = WIDEQ::Auth.from_url gateway, callback_url
    state = client.dump
    store_credentials state
  end

  ##
  # List the client devices
  no_commands do
    def ls(client)
      client.devices&.each do |device|
        puts "#{device.id}: \"#{device.name}\" (type #{device.type}, id #{device.model_id})"
      end
    end
  end

  ##
  # Monitor any device, displaying generic information about its status
  no_commands do
    def mon(client, device_id)
      device = client.get_device(device_id)
      model = client.model_info device

      influxdb = InfluxDB::Client.new 'lge' unless options[:dry_run]
      tags = { device_id: device.id,
               device_name: device.name,
               device_type: device.type,
               device_model_id: device.model_id }

      mon = WIDEQ::Monitor.new client.session, device_id

      begin
        mon.start
        begin
          got_data = false
          until got_data
            sleep 1
            @logger.info 'polling...'
            data = mon.poll
            timestamp = Time.now.to_i
            next if data.nil?

            got_data = true

            begin
              res = model.decode_monitor(data)
            rescue WIDEQ::MonitorError => e
              @logger.warn "error decoding exception #{e}"
            else
              res.each do |key, value|
                desc = model.value(key)
                case desc.class.to_s
                when 'WIDEQ::EnumValue'
                  @logger.info "- ENUM: #{key}: #{value} / #{desc.options[value.to_s]}"
                  if key == 'State'
                    data = [{ series: 'state',             values: { value: value },                    tags: tags, timestamp: timestamp },
                            { series: 'state_description', values: { value: desc.options[value.to_s] }, tags: tags, timestamp: timestamp }]
                    @logger.debug data
                    influxdb.write_points data unless options[:dry_run]
                  end
                when 'WIDEQ::RangeValue'
                  @logger.info "- RANGE #{key}: #{value} (#{desc.min} - #{desc.max})"
                when 'WIDEQ::ReferenceValue'
                  @logger.info "- REFERENCE: #{key}: #{value} / #{model.reference_name(key, value.to_s)}"
                  if key.include? 'Course'
                    series = key.downcase
                    data = [{ series: series,                  values: { value: value },                                 tags: tags, timestamp: timestamp },
                            { series: "#{series}_description", values: { value: model.reference_name(key, value.to_s) }, tags: tags, timestamp: timestamp }]
                    @logger.debug data
                    influxdb.write_points data unless options[:dry_run]
                  end
                when 'WIDEQ::BitValue'
                  # @logger.info "- BIT: #{key}: #{value} #{desc.options[value.to_s]} / #{model.bit_name key, value, value.to_s}"
                  @logger.info "- BIT: #{key}: #{value} #{desc.options[value.to_s]}"
                else
                  @logger.info "- UNDECODABLE #{desc} #{key}: #{value}"
                end
              end
            end
          end
        ensure
          mon.stop
        end
      rescue WIDEQ::DeviceNotConnectedError
        @logger.info "#{device.name} is not connected"
        timestamp = Time.now.to_i
        data = [{ series: 'state',              values: { value: 0   }, tags: tags, timestamp: timestamp },
                { series: 'state_description',  values: { value: '-' }, tags: tags, timestamp: timestamp }]
        @logger.debug data
        influxdb.write_points data unless options[:dry_run]

        data = nil
        case device.type
        when :DRYER
          data = [{ series: 'course',             values: { value: 0   }, tags: tags, timestamp: timestamp },
                  { series: 'course_description', values: { value: '-' }, tags: tags, timestamp: timestamp }]
        when :WASHER
          data = [{ series: 'apcourse',             values: { value: 0   }, tags: tags, timestamp: timestamp },
                  { series: 'apcourse_description', values: { value: '-' }, tags: tags, timestamp: timestamp }]
        end
        @logger.debug data
        influxdb.write_points data unless options[:dry_run]
      end # begin main block
    end # def mon
  end # no_commands

  no_commands do
    def main
      begin
        state = load_credentials
      rescue StandardError
        state = {}
      end

      @logger.debug state
      client = WIDEQ::Client.load(state)
      @logger.debug client._auth
      # Log in if we don't already have an authentication
      raise WIDEQ::NotLoggedInError unless client._auth

      soft_faults = [Net::OpenTimeout,
                     Net::ReadTimeout,
                     RestClient::Exceptions::OpenTimeout,
                     RestClient::Exceptions::ReadTimeout,
                     SocketError]

      begin
        with_rescue(soft_faults, @logger) do |_try|
          ls client
        end
      rescue WIDEQ::NotLoggedInError
        @logger.info 'Session expired, refreshing'
        client.refresh
      rescue StandardError => e
        @logger.error 'Rescuing a StandardError after call to ls **************************'
        @logger.error e
      end

      # Save the updated state.
      state = client.dump
      store_credentials state

      @logger.debug client

      client.devices&.each do |device|
        begin
          with_rescue(soft_faults, @logger) do |_try|
            mon client, device.id
          end
        rescue StandardError => e
          @logger.error 'Rescuing a StandardError after call to mon **************************'
          @logger.error e.full_message
        end
      end
    end
  end
end

LG.start
