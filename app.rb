require 'datyl/logger'
require 'store'
require 'store/silodb'
require 'store/silotape'

# TODO: transfer compression in PUT seems to retain files as compressed...fah.

def get_config
  filename = ENV['SILOPOOL_CONFIG_FILE'] || File.join(File.dirname(__FILE__), 'config.yml')
  config = StoreUtils.read_config(filename)
end

configure do
  $KCODE = 'UTF8'

  # boiler plate

  disable :logging        # Stop CommonLogger from logging to STDERR, please.
  disable :dump_errors    # Set to true in 'classic' style apps (of which this is one) regardless of :environment; it
                          # adds a backtrace to STDERR on all raised errors (even those we properly handle). Not so good.

  set :environment,  :production             # Get some exceptional defaults.
  set :raise_errors,  false                  # Handle our own errors

  # our app-specific settings:

  config = get_config

  set :tivoli_server, config.tivoli_server
  set :silo_temp, config.silo_temp_directory
  set :database_connection_string, config.database_connection_string
  set :fixity_stale_days, config.fixity_stale_days
  set :fixity_expired_days, config.fixity_expired_days

  Logger.setup 'SiloPool', config.virtual_hostname

  if config.log_syslog_facility
    Logger.facility = config.log_syslog_facility
  else
    Logger.stderr
  end

  Logger.info "Starting #{Store.version.name}; Tivoli server is #{settings.tivoli_server || 'not defined.' }."

  DataMapper::Logger.new(Logger.new(:info, 'DataMapper:'), :debug) if config.log_database_queries

  Store::DB.setup settings.database_connection_string

  ENV['TMPDIR'] = config.temp_directory if config.temp_directory
end


before do
  @started = Time.now
  raise Http401, 'You must provide a basic authentication username and password' if needs_authentication?
end

after do
  log_end_of_request @started
end

load 'lib/app/helpers.rb'
load 'lib/app/errors.rb'
load 'lib/app/gets.rb'
load 'lib/app/puts.rb'
load 'lib/app/posts.rb'
load 'lib/app/deletes.rb'
