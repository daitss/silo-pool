require 'store/silodb'
require 'store/exceptions'
require 'store/poolreservation'
require 'builder'

post '/create/:name' do |name|
  
  log_start_of_request

  # TODO: check if name is new across entire set of silos in a pool; we have uniqueness 
  # for names within a silo,  but perhaps we want it across all of them?  StorageMaster
  # does guarentee this by workflow, but packages may appear in other ways (old PUT,
  # local creation, restore from inconsistent backup...)
  
  raise SiloBadName, "The identifier #{name} does not meet our resource naming convention"    unless good_name name
  raise MissingMD5,  "Missing the Content-MD5 header, required for POSTs to #{this_resource}" unless request_md5
  raise MissingTar,  "#{this_resource} only accepts content types of application/x-tar"       unless request.content_type == 'application/x-tar'

  silo = nil

  # Note: PoolReservation checks for 'put' permissions on silos (thought is is technically not a PUT,
  # we use that designation in the pool administration GUI to limit the set of writable silos)
  silo = Object.new
  PoolReservation.new(request.content_length.to_i) do |s|
    s.put(name, request.body, request.content_type || 'application/x-tar')
    silo = s
  end

  computed_md5 = silo.md5(name)

  if computed_md5 != request_md5
    silo.delete(name) if silo.exists?(name)
    raise MD5Mismatch, "The request indicated the MD5 was #{request_md5}, but the server computed #{computed_md5}"
  end

  loc = web_location(silo.filesystem.split('/')[-1], name)    # last part of the filesystem directory path is unique name of silo

  status 201
  headers 'Location' => loc, 'Content-Type' => 'application/xml'

  xml = Builder::XmlMarkup.new(:indent => 2)
  xml.instruct!(:xml, :encoding => 'UTF-8')
  xml.created(:name     => name,
              :etag     => silo.etag(name),
              :md5      => silo.md5(name),
              :sha1     => silo.sha1(name),
              :size     => silo.size(name),
              :type     => silo.type(name),
              :time     => silo.datetime(name).to_s,
              :location => loc)
  xml.target!
end


post '/:partition/knobs/allowed-methods' do |partition|
  silo       = get_silo(partition)

  if params[:'selected-methods'].nil?
    allowed = []
  else
    allowed = params[:'selected-methods'].map{ |m| text_to_method(m) }
  end

  forbidden  = silo.possible_methods - allowed

  Logger.warn "Request from #{@env['REMOTE_ADDR']} to change allowed methods of #{silo.filesystem} from [#{silo.allowed_methods.map { |m| method_to_text(m) }. join(', ')}] to [#{ allowed.map { |m| method_to_text(m) }. join(', ')}]."

  forbidden.each { |m| silo.forbid(m) }
  allowed.each   { |m| silo.allow(m) }

  redirect absolutely("/silos/")
end


post '/new-silo?' do
  new_filesystem = params[:new_filesystem]
  raise BadFilesystem, "filesystem wasn't specified" unless new_filesystem.class == String
  
  raise BadFilesystem, "#{new_filesystem} is already listed as a silo" if Store::DB::SiloRecord.lookup(hostname, new_filesystem)

  Logger.warn "Request from #{@env['REMOTE_ADDR']} to add silo #{new_filesystem}"

  raise BadFilesystem, "#{new_filesystem} doesn't exist"      unless File.exists? new_filesystem
  raise BadFilesystem, "#{new_filesystem} isn't a directory"  unless File.directory? new_filesystem
  raise BadFilesystem, "#{new_filesystem} isn't writable"     unless File.writable? new_filesystem
  raise BadFilesystem, "#{new_filesystem} isn't a readable"   unless File.readable? new_filesystem
  raise BadFilesystem, "#{new_filesystem} needs to be owned by #{StoreUtils.user}"  unless StoreUtils.user == StoreUtils.user(new_filesystem)

  rec = Store::SiloDB.create(hostname, new_filesystem.strip)

  raise "Database record for new silo at #{new_filesystem} could not be created: " + rec.errors.full_messages.join('; ') unless rec and rec.saved?

  redirect absolutely("/#{rec.short_name}/knobs/")
end


post '/credentials?' do

  case params[:action]

  when /clear password/i
    Logger.warn "Request from #{@env['REMOTE_ADDR']} to remove password protection for this silo pool."
    DB::Authentication.clear

  when /change password/i, /set password/i
    Logger.warn "Request from #{@env['REMOTE_ADDR']} to change the password protection for this silo pool."
    DB::Authentication.create('admin', params[:password])
  end

  redirect absolutely("/silos/")
end


post '/:partition/knobs/allowed-states' do |partition|

  silo      = get_silo(partition)
  new_state = text_to_state(params[:state])

  Logger.warn "Request from #{@env['REMOTE_ADDR']} to change state of #{silo.filesystem} from #{state_to_text(silo.state)} to #{state_to_text(new_state)}."

  silo.state new_state if silo.state != new_state
  redirect absolutely("/silos/")
end


post '/:partition/knobs/retire-silo' do |partition|

  silo      = get_silo(partition)
  do_retire = params[:retire] == 'true'

  redirect absolutely("/silos/") if (do_retire and silo.retired?) or (not do_retire and not silo.retired?)

  if do_retire
    Logger.warn "Request from #{@env['REMOTE_ADDR']} to retire #{silo.filesystem}." 
    silo.retire
  else
    Logger.warn "Request from #{@env['REMOTE_ADDR']} to un-retire #{silo.filesystem}." 
    silo.reactivate    
  end

  redirect absolutely("/silos/")   
end



