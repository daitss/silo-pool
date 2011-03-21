require 'datyl/logger'
require 'store'
require 'store/silodb'
require 'store/silotape'

# TODO: transfer compression in PUT seems to retain files as compressed...fah.  Need to check for this...

# configure expects some environment variables (typically set up in config.ru, which sets development
# defaults and may be over-ridden from either the command line or apache SetEnv directives):
#
#   DATABASE_CONFIG_FILE   a yaml configuration file that contains database information (see SiloDB)
#   DATABASE_CONFIG_KEY    a key into a hash provided by the above file
#   DATABASE_LOGGING       if set to any value, do verbose datamapper logging
#   LOG_FACILITY           if set, use that value as the syslog facility code;  otherwise stderr (see Logger)
#   SILO_TEMP              a temporary directory for us to write mini-silos to from tape (see SiloTape).
#   TIVOLI                 the name of the tape robot (see SiloTape and TsmExecutor).

configure do
  $KCODE = 'UTF8'

  disable :logging        # Stop CommonLogger from logging to STDERR, please.
  disable :dump_errors    # Set to true in 'classic' style apps (of which this is one) regardless of :environment; it
                          # adds a backtrace to STDERR on all raised errors (even those we properly handle). Not so good.

  set :environment,  :production             # Get some exceptional defaults.
  set :raise_errors,  false                  # Handle our own errors

  set :tivoli_server, ENV['TIVOLI_SERVER']
  set :silo_temp,     ENV['SILO_TEMP']       

  Logger.setup('SiloPool', ENV['VIRTUAL_HOSTNAME'])

  ENV['LOG_FACILITY'].nil? ? Logger.stderr : Logger.facility  = ENV['LOG_FACILITY']

  use Rack::CommonLogger, Logger.new(:info, 'Rack:')

  Logger.info "Starting #{Store.version.name}; Tivoli server is #{ENV['TIVOLI_SERVER'] || 'not defined.' }."
  Logger.info "Connecting to the DB using key '#{ENV['DATABASE_CONFIG_KEY']}' with configuration file #{ENV['DATABASE_CONFIG_FILE']}."

  (ENV.keys - ['TIVOLI_SERVER', 'DATABASE_CONFIG_KEY', 'DATABASE_CONFIG_FILE']).sort.each do |key|
    Logger.info "Environment: #{key} => #{ENV[key].nil? ? 'undefined' : "'" + ENV[key] +"'"}"
  end

  DataMapper::Logger.new(Logger.new(:info, 'DataMapper:'), :debug) if  ENV['DATABASE_LOGGING']

  begin
    Store::SiloDB.setup ENV['DATABASE_CONFIG_FILE'], ENV['DATABASE_CONFIG_KEY']
  rescue Store::ConfigurationError => e
    Logger.err e.message
    raise e
  rescue => e
    Logger.err e.message
    e.backtrace.each { |line| Logger.err e.message }
    raise e
  end
end

load 'lib/app/helpers.rb'
load 'lib/app/errors.rb'
load 'lib/app/gets.rb'
load 'lib/app/puts.rb'
load 'lib/app/posts.rb'
load 'lib/app/deletes.rb'
