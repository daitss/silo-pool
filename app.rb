# encoding: UTF-8
require 'datyl/config'
require 'datyl/logger'
require 'socket'
require 'store'
require 'store/exceptions'
require 'store/silodb'
require 'store/silotape'

include Datyl   # gets Logger, Config interface (in case of latter, we have a conflict, specify Datyl::Config)

def get_config

  raise Store::ConfigurationError, "No DAITSS_CONFIG environment variable has been set, so there's no configuration file to read"             unless ENV['DAITSS_CONFIG']
  raise ConfigurationError, "The VIRTUAL_HOSTNAME environment variable has not been set"                                                      unless ENV['VIRTUAL_HOSTNAME']
  raise Store::ConfigurationError, "The DAITSS_CONFIG environment variable points to a non-existant file, (#{ENV['DAITSS_CONFIG']})"          unless File.exists? ENV['DAITSS_CONFIG']
  raise Store::ConfigurationError, "The DAITSS_CONFIG environment variable points to a directory instead of a file (#{ENV['DAITSS_CONFIG']})"     if File.directory? ENV['DAITSS_CONFIG']
  raise Store::ConfigurationError, "The DAITSS_CONFIG environment variable points to an unreadable file (#{ENV['DAITSS_CONFIG']})"            unless File.readable? ENV['DAITSS_CONFIG']
  
  config = Datyl::Config.new(ENV['DAITSS_CONFIG'], :defaults, :database, ENV['VIRTUAL_HOSTNAME'])

  raise Store::ConfigurationError, "The database connection string ('silo_db') was not found in the configuration file #{ENV['DAITSS_CONFIG']}" unless config.silo_db

  return config
end


configure do
                  

  set :logging,     false        # Stop CommonLogger from logging to STDERR
  set :dump_errors, false        # Don't add backtraces automatically (we'll decide)
  set :environment, :production  # Get some exceptional defaults.
  set :raise_errors, false       # Let our app handle the exceptions.

  config = get_config()

  set :tivoli_server,         config.tivoli_server
  set :silo_temp_directory,   config.silo_temp_directory   || '/var/tmp'
  set :fixity_stale_days,     config.fixity_stale_days     || 45
  set :fixity_expired_days,   config.fixity_expired_days   || 60

  Logger.setup 'SiloPool', ENV['VIRTUAL_HOSTNAME']

  Logger.facility = config.log_syslog_facility  if config.log_syslog_facility
  Logger.filename = config.log_filename         if config.log_filename

  Logger.stderr unless (config.log_filename or config.log_syslog_facility)

  use Rack::CommonLogger, Logger.new(:info, 'Rack:')  # Bend CommonLogger to our logging system

  Logger.info "Starting #{Store.version.name}; Tivoli server is #{settings.tivoli_server || 'not defined.' }."
  Logger.info "Using #{ENV['TMPDIR'] || 'system default'} for temp directory"
  Logger.info "Using database #{StoreUtils.safen_connection_string(config.silo_db)}"

  DataMapper::Logger.new(Logger.new(:info, 'DataMapper:'), :debug) if config.log_database_queries

  Store::DB.setup config.silo_db
end

before do
  @started = Time.now
  raise Http401, 'You must provide a basic authentication username and password' if needs_authentication?
end

load 'lib/app/helpers.rb'
load 'lib/app/errors.rb'
load 'lib/app/gets.rb'
load 'lib/app/puts.rb'
load 'lib/app/posts.rb'
load 'lib/app/deletes.rb'
