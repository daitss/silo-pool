require 'store'
require 'store/silodb'
require 'store/silotape'
require 'store/logger'

# TODO: use LOG_TAG maybe
# TODO: hook logger to datamapper
# TODO: transfer compression in PUT seems to retain files as compressed...fah.  Need to check for this...

# configure expects some environment variables (typically set up in config.ru, which sets development
# defaults and may be over-ridden from either the command line or apache SetEnv directives):
#
#   DATABASE_CONFIG_FILE   a yaml configuration file that contains database information (see SiloDB)
#   DATABASE_CONFIG_KEY    a key into a hash provided by the above file
#   LOG_FACILITY           if set, use as the syslog facility code;  otherwise stderr (see Logger)
#   LOG_TAG                optional, used to add information to our logging, usually the virtual host name (see Logger)
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

  Logger.setup('SiloPool')  # TODO: add vhost second arg

  ENV['LOG_FACILITY'].nil? ? Logger.stderr : Logger.facility  = ENV['LOG_FACILITY']

  use Rack::CommonLogger, Logger.new

  Logger.info "Starting #{Store.version.rev}."
  Logger.info "Initializing with data directory #{ENV['SILO_ROOT']}; Tivoli server is #{ENV['TIVOLI_SERVER'] || 'not defined.' }."

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

