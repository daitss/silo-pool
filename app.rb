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
  raise Store::ConfigurationError, "The DAITSS_CONFIG environment variable points to a non-existant file, (#{ENV['DAITSS_CONFIG']})"          unless File.exists? ENV['DAITSS_CONFIG']
  raise Store::ConfigurationError, "The DAITSS_CONFIG environment variable points to a directory instead of a file (#{ENV['DAITSS_CONFIG']})"     if File.directory? ENV['DAITSS_CONFIG']
  raise Store::ConfigurationError, "The DAITSS_CONFIG environment variable points to an unreadable file (#{ENV['DAITSS_CONFIG']})"            unless File.readable? ENV['DAITSS_CONFIG']
  
  config = Datyl::Config.new(ENV['DAITSS_CONFIG'], :defaults, :database, :silo)

  raise Store::ConfigurationError, "The database connection string ('silo_db') was not found in the configuration file #{ENV['DAITSS_CONFIG']}" unless config.silo_db

  return config
end


configure do
  $KCODE = 'UTF8'

  # boiler plate settings

  disable :logging        # Stop CommonLogger from logging to STDERR, please.
  disable :dump_errors    # Set to true in 'classic' style apps (of which this is one) regardless of :environment; it
                          # adds a backtrace to STDERR on all raised errors (even those we properly handle). Not so good.

  set :environment,  :production             # Get some exceptional defaults.
  set :raise_errors,  false                  # Handle our own errors

  # our app-specific settings:

  config = get_config

  ENV['TMPDIR'] = config.temp_directory if config.temp_directory

  set :tivoli_server,              config.tivoli_server
  set :silo_temp_directory,        config.silo_temp_directory   || '/var/tmp'
  set :fixity_stale_days,          config.fixity_stale_days     || 45
  set :fixity_expired_days,        config.fixity_expired_days   || 60

  Logger.setup 'SiloPool', (config.virtual_hostname || Socket.gethostname)

  if config.log_syslog_facility
    Logger.facility = config.log_syslog_facility
  else
    Logger.stderr
  end

  use Rack::CommonLogger, Logger.new(:info, 'Rack:')  # Bend CommonLogger to our will...

  Logger.info "Starting #{Store.version.name}; Tivoli server is #{settings.tivoli_server || 'not defined.' }."
  Logger.info "Using temp directory #{config.temp_directory}" if config.temp_directory
  Logger.info "Using database #{StoreUtils.safen_connection_string(config.silo_db)}"

  # TODO: log rest of config options?

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
