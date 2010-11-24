require 'store'
require 'store/silodb'     # TODO: get all this moved into lib/store.rb
require 'store/silotape'
require 'store/logger'


# require 'ruby-prof'

# TODO: hook logging to datamapper
# TODO: transfer compression in PUT seems to retain files as compressed...fah.  Need to check for this...

configure do
  $KCODE = 'UTF8'

  disable :logging        # Stop CommonLogger from logging to STDERR, please.
  disable :dump_errors    # Set to true in 'classic' style apps (of which this is one) regardless of :environment; it
                          # adds a backtrace to STDERR on all raised errors (even those we properly handle). Not so good.

  set :environment,  :production             # Get some exceptional defaults.

  set :raise_errors,  false                  # We handle our own errors...

  set :tivoli_server, ENV['TIVOLI_SERVER']   # Where to find the tape robot (see SiloTape and TsmExecutor).
  set :silo_root,     ENV['SILO_ROOT']       # All of our disk-based silos are locally mounted under this directory (see SiloDB).
  set :silo_temp,     ENV['SILO_TEMP']       # A temporary directory for us to write mini-silos to from tape (see SiloTape).

  if ENV['LOG_FACILITY'].nil?
    Logger.stderr
  else
    Logger.facility  = ENV['LOG_FACILITY']
  end


  use Rack::CommonLogger, Logger.new

  Logger.info "Starting #{Store.version.rev}."
  Logger.info "Initializing with data directory #{ENV['SILO_ROOT']}; Tivoli server is #{ENV['TIVOLI_SERVER'] || 'not defined.' }."

  # @env.each { |k,v| Logger.info "ENV[#{k}] => #{v.inspect}" }

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

# TODO: create profiling browser

before do
  @@app_start ||= DateTime.now   # surely I can do *something* with this...
  RubyProf.start if profile?
end

after do
  if profile?
    results = RubyProf.stop

    flat  = RubyProf::FlatPrinter.new(results)
    call  = RubyProf::CallTreePrinter.new(results) 
    graph = RubyProf::GraphHtmlPrinter.new(results)

    open(profile_filename(:whence), 'w')    { |fh|  fh.puts request.url }
    open(profile_filename(:flat), 'w')      { |fh|  flat.print(fh, 0) }
    open(profile_filename(:call_tree), 'w') { |fh|  call.print(fh, 0) }
    open(profile_filename(:graph), 'w')     { |fh|  graph.print(fh, :min_percent => 0) }
  end
end

