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
    return 'application/xml'  if name =~ /\.mets$/
    return 'application/xml'  if name =~ /\.xsd$/
    return 'text/plain'       if name =~ /\.pro$/
    # iana:
    mime = MIME::Types.type_for(name)[0]
    mime.nil? ? 'application/octet-stream' : mime.content_type
  end

  def xml_escape str
    str.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub("'", '&apos;').gsub('"', '&quot;')
  end

  def filesystem_to_text str
    'silo /' + str.split('/').pop
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
    list_silos.each { |silo| return silo.filesystem if silo.filesystem =~ /#{silo_partition}$/ }
    nil
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

  # An alternative to send_file I'd prefer to use (send_file doesn't
  # do last-modified time flexibly enough). Not used right now, but 
  # keep around for the TODO: exactly what were the issues with this
  # vs. send_file?   

  class SiloBuffer
    def initialize silo, name
      @silo = silo;  @name = name
    end
    def each 
      silo.get(name) { |buff| yield buff }
    end
  end


  def start_time
    @@app_start.to_s
  end


  # Assumes we're in the file .../lib/app/<something.rb>, figure out what our
  # temporary directory is.
  #
  # TODO: we'd really like to get the app root off of the appropriate object... a rack object? 

  def my_tmp
    File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'tmp'))
  end

  
  # Check if <app>/tmp/profile.txt  is newer than <app>/tmp/restart.txt. If so,
  # it's an indication we should be profiling: return true
                     
  def profile?
    restart_stamp = File.join(my_tmp, 'restart.txt')
    profile_stamp = File.join(my_tmp, 'profile.txt')

    File.exists?(restart_stamp) and File.exists?(profile_stamp) and (File.mtime(profile_stamp) > File.mtime(restart_stamp))
  end
  
  # Come up with a name to save profiling info to - we suport :graph, :html and :flat
  # TODO: put these files somewhere sensible and come up with a set of views that will display these results
  # (note to self: without profiling the presentation of the view....)

  def profile_filename type
    epoch = DateTime.now.strftime('%s').to_s

    case type
    when :whence
      File.join(my_tmp, epoch + '.' + 'whence')   # used for recording what URL we were in
    when :graph
      File.join(my_tmp, epoch + '.' + type.to_s + '.' + 'html')
    else
      File.join(my_tmp, epoch + '.' + type.to_s + '.' + 'prof')
    end
  end

  # pretty_count(silo)
  #
  # pretty print the count of the numnber of packages in a silo, returning as a string.

  def pretty_count silo
    StoreUtils.commify(silo.package_count)
  end

  # pretty_free(silo)
  #
  # pretty print the free disk size for a silo along the lines of 'df -h', returning as a string.

  def pretty_free silo    
    size = StoreUtils.disk_free(silo.filesystem)
    if    size > 1_000_000_000_000;  StoreUtils.commify(sprintf("%5.2f TB",  size / 1_000_000_000_000.0))
    elsif size > 1_000_000_000;      StoreUtils.commify(sprintf("%5.2f GB",  size / 1_000_000_000.0))
    elsif size > 1_000_000;          StoreUtils.commify(sprintf("%5.2f MB",  size / 1_000_000.0))
    elsif size > 1_000;              StoreUtils.commify(sprintf("%5.2f KB",  size / 1_000.0))
    else                             StoreUtils.commify(sprintf("%5.2f B",   size))      
    end
  end

end



