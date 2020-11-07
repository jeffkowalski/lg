#!/usr/bin/env ruby
# frozen_string_literal: true

require 'logger'
require 'wideq'
require 'influxdb'
require 'thor'
require 'yaml'

LOGFILE = File.join(Dir.home, '.log', 'lg.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'lg.yaml')

class LG < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

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
    callback_url = STDIN.gets.chomp
    client._auth = WIDEQ::Auth.from_url gateway, callback_url
    state = client.dump
    File.open(CREDENTIALS_PATH, 'w') { |file| file.write state.to_yaml }
  end

  ##
  # List the client devices
  no_commands do
    def ls(client)
      client.devices.each do |device|
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
      rescue WIDEQ::DeviceNotConnectedError
        $logger.info "#{device.name} is not connected"
        timestamp = Time.now.to_i
        data = [{ series: 'state',              values: { value: 0   }, tags: tags, timestamp: timestamp },
                { series: 'state_description',  values: { value: '-' }, tags: tags, timestamp: timestamp }]
        $logger.debug data
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
        $logger.debug data
        influxdb.write_points data unless options[:dry_run]
      else
        begin
          iters = 0
          while iters.zero?
            sleep 1
            $logger.info 'polling...'
            data = mon.poll
            next if data.nil?

            timestamp = Time.now.to_i
            iters += 1
            begin
              res = model.decode_monitor(data)
            rescue WIDEQ::MonitorError => e
              $logger.warn "error decoding exception #{e}"
            else
              res.each do |key, value|
                desc = model.value(key)
                if desc.is_a? WIDEQ::EnumValue
                  $logger.info "- ENUM: #{key}: #{value} / #{desc.options[value.to_s]}"
                  if key == 'State'
                    data = [{ series: 'state',             values: { value: value },                    tags: tags, timestamp: timestamp },
                            { series: 'state_description', values: { value: desc.options[value.to_s] }, tags: tags, timestamp: timestamp }]
                    $logger.debug data
                    influxdb.write_points data unless options[:dry_run]
                  end
                elsif desc.is_a? WIDEQ::RangeValue
                  $logger.info "- RANGE #{key}: #{value} (#{desc.min} - #{desc.max})"
                elsif desc.is_a? WIDEQ::ReferenceValue
                  $logger.info "- REFERENCE: #{key}: #{value} / #{model.reference_name(key, value.to_s)}"
                  if key.include? 'Course'
                    series = key.downcase
                    data = [{ series: series,                  values: { value: value },                                 tags: tags, timestamp: timestamp },
                            { series: "#{series}_description", values: { value: model.reference_name(key, value.to_s) }, tags: tags, timestamp: timestamp }]
                    $logger.debug data
                    influxdb.write_points data unless options[:dry_run]
                  end
                elsif desc.is_a? WIDEQ::BitValue
                  # $logger.info "- BIT: #{key}: #{value} #{desc.options[value.to_s]} / #{model.bit_name key, value, value.to_s}"
                  $logger.info "- BIT: #{key}: #{value} #{desc.options[value.to_s]}"
                else
                  $logger.info "- UNDECODABLE #{key}: #{value}"
                end
              end
            end
          end
        rescue StandardError => e
          @logger.error e
        ensure
          mon.stop
        end
      end
    end
  end

  desc 'record-status', 'record the current usage data to database'
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def record_status
    setup_logger

    begin
      state = YAML.load_file CREDENTIALS_PATH
    rescue StandardError
      state = {}
    end

    client = WIDEQ::Client.load(state)
    pp state
    pp client._auth
    # Log in if we don't already have an authentication
    raise WIDEQ::NotLoggedInError unless client._auth

    begin
      ls client
    rescue WIDEQ::NotLoggedInError
      $logger.info 'Session expired, refreshing'
      client.refresh
    rescue StandardError => e
      @logger.error e
    end

    # Save the updated state.
    state = client.dump
    File.open(CREDENTIALS_PATH, 'w') { |file| file.write state.to_yaml }

    # pp client

    client.devices.each do |device|
      mon client, device.id
    end
  end
end

ENV['OPENSSL_CONF'] = 'openssl.cnf'
LG.start
