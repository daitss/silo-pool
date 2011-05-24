require 'store/exceptions' 
require 'store/utils'
require 'mime/types'

helpers do
  include Rack::Utils     # to get escape_html

  def this_resource 
    absolutely @env['SCRIPT_NAME'].gsub(%r{/+$}, '') + '/' + @env['PATH_INFO'].gsub(%r{^/+}, '')
  end

  # always return a number

  def safe_number str
    str.to_i > 0 ? str.to_i : 1
  rescue 
    1
  end

  def fixity_time silo
    ts = silo.oldest_fixity
    ts.nil? ? '' : ts.strftime('%Y-%m-%d %X')
  end

  def mime_type_by_filename name
    # local color:
    return 'application/xml'  if name =~ /\.mets$/i
    return 'application/xml'  if name =~ /\.xsd$/i
    return 'text/plain'       if name =~ /\.pro$/i
    # IANA:
    mime = MIME::Types.type_for(name)[0]
    mime.nil? ? 'application/octet-stream' : mime.content_type
  end

  def filesystem_to_text str
    '/' + str.split('/').pop
  end

  def state_to_text symbol
    raise "unknown silo state symbol #{symbol}, can't convert to text" unless [:tape_master, :disk_master, :disk_idling].include? symbol
    symbol.to_s.downcase.gsub('_', ' ')
  end

  def text_to_state text
    state_text = text.gsub(' ', '_').downcase
    raise "unknown silo state text #{text}, can't convert to symbol" unless ['tape_master', 'disk_master', 'disk_idling'].include? state_text
    state_text.to_sym
  end

  # silo methods

  def method_to_text symbol
    raise "unknown silo method symbol #{symbol}, can't convert to text" unless [ :get, :put, :delete, :post ].include? symbol
    symbol.to_s.downcase
  end

  def text_to_method text
    method_text = text.downcase
    raise "unknows silo method text #{text}, can't convert to symbol" unless ['get', 'put', 'delete', 'post'].include? method_text
    method_text.to_sym
  end

  def absolutely path
    'http://' + hostname + port_maybe + path
  end

  # Reformat the exception message when we have a Store::Http

  def store_http_error_message exception
    "#{exception.status_code} #{exception.status_text} - #{exception.message}\n"
  end

  def port_maybe
    @env['SERVER_PORT'].to_s == "80" ? "" : ":#{@env['SERVER_PORT']}"
  end

  def port
    @env['SERVER_PORT'].to_s
  end

  # HTTP_HOST can be borken - comes with port attached!

  def hostname
    (@env['HTTP_HOST'] || @env['SERVER_NAME']).gsub(/:\d+$/, '')
  end

  def good_name name
    ### name =~ /^E\d{8}_[A-Z]{6}$/
    name =~ /^E[A-Z0-9]{8}_[A-Z0-9]{6}(\.[0-9]{3})?$/    # ieid or ieid.vers  accepted
  end

  def request_md5
    StoreUtils.base64_to_md5hex(@env["HTTP_CONTENT_MD5"])
  end

  def web_location partition, name = ''
    absolutely "/#{partition}/data/#{name}"
  end

  # we may want to add another column in the silos table to account for the name.
 
  def filesystem_location silo_partition
    return unless rec = DB::SiloRecord.lookup_by_partition(hostname, silo_partition)
    rec.filesystem
  end

  def methods_hash silo
    hash = {}
    silo.possible_methods.each { |meth|  hash[meth.to_s] = false }
    silo.allowed_methods.each  { |meth|  hash[meth.to_s] = true }
    hash
  end

  def states_hash silo
    hash = { 'disk_master' => false, 'tape_master' => false, 'disk_idling' => false }
    hash[silo.state.to_s] = true
    hash
  end

  # crock.  should only be one silo class....

  def list_silos
    silos = []
    SiloDB.silos(hostname).sort{ |a,b| a.filesystem <=> b.filesystem }.each do |rec|
      case rec.media_device
      when :disk
        silos.push SiloDB.new(hostname, rec.filesystem)
      when :tape
        silos.push SiloTape.new(hostname, rec.filesystem, settings.silo_temp, settings.tivoli_server)
      end
    end
    silos
  end

  # Look up the silo from our virtual hostname and the supplied
  # partition.  If name is given, check to make sure it exists.  This
  # helper method exists to select the right type of silo (disk- or
  # tape-based) and to throw a 404 on bad routes.

  # crock.  should only be one silo class....

  def get_silo partition, name = nil

    dir = filesystem_location(partition)
    
    raise Http404, "The resource #{web_location(partition)} doesn't exist" if dir.nil?

    rec = DB::SiloRecord.lookup hostname, dir

    raise Http404, "The resource #{web_location(partition)} doesn't exist" if rec.nil?

    silo = nil

    case rec.media_device

    when :disk
      raise Http404, "The resource #{web_location(partition)} doesn't exist" unless File.directory? dir  ### this is a mistake
      silo = SiloDB.new(hostname, dir)
      raise Http404, "The resource #{web_location(partition, name)} does not exist" if name and not silo.exists?(name)

    when :tape
      silo = SiloTape.new(hostname, dir, settings.silo_temp, settings.tivoli_server)
      raise Http404, "The resource #{web_location(partition, name)} does not exist" if name and not silo.exists?(name)

    else
      raise "Unknown silo media '#{rec.media_device}'"
    end
    
    silo
  end

  
  # pretty_count(silo)
  #
  # pretty print the count of the numnber of packages in a silo, returning as a string.

  def pretty_count silo
    StoreUtils.commify(silo.package_count)
  end

  # pretty_free(silo)
  #
  # pretty print the free disk size for a silo, returning as a string.

  def pretty_free silo
    if File.exists?(silo.filesystem) and File.directory?(silo.filesystem) and File.readable?(silo.filesystem)
      pretty_size(StoreUtils.disk_free(silo.filesystem))
    else
      'n/a'
    end
  end

  # pretty_size size
  #
  # pretty print the supplied number +size+ along the lines of 'df -h' but with
  # American style punctuation, returning as a string.

  def pretty_size size
    if    size > 1_000_000_000_000;  StoreUtils.commify(sprintf("%5.2f TB",  size / 1_000_000_000_000.0))
    elsif size > 1_000_000_000;      StoreUtils.commify(sprintf("%5.2f GB",  size / 1_000_000_000.0))
    elsif size > 1_000_000;          StoreUtils.commify(sprintf("%5.2f MB",  size / 1_000_000.0))
    elsif size > 1_000;              StoreUtils.commify(sprintf("%5.2f KB",  size / 1_000.0))
    else                             StoreUtils.commify(sprintf("%5.2f B",   size))      
    end
  end

  # check to see if we've got an admin password on file - if so, check the request to see
  # if the client supplied the correct username (admin) and password.

  def needs_authentication?

    return false unless request.put? or request.delete? or request.post?

    admin_credentials = DB::Authentication.lookup('admin')

    return false if admin_credentials.nil?                    # we don't require authentication

    auth =  Rack::Auth::Basic::Request.new(request.env)

    if auth.provided? && auth.basic? && auth.credentials 
      user, password = auth.credentials
      return (user != 'admin' or not admin_credentials.authenticate(password))
    else
      return true
    end
  end

  def rewind_maybe
    request.body.rewind if request.body.respond_to?('rewind')  
  end

  def safe_silo_size silo, name
    pretty_size(silo.size(name))
  rescue => e
    Logger.err "Error when retrieving size information for #{name} from #{silo}: #{e.class} - #{e.message}"
    'error'
  end

  def safe_silo_datetime silo, name
    silo.datetime(name).strftime("%B %d, %Y - %r")
  rescue => e
    Logger.err "Error when retrieving date information for #{name} from #{silo}: #{e.class} - #{e.message}"
    'error'
  end

end
