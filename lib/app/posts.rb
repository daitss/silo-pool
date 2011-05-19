require 'store/silodb'
require 'store/exceptions'
require 'store/poolreservation'
require 'builder'

post '/create/:name' do |name|

  # TODO: check if name is unique accross entire set of pools.
  
  raise SiloBadName, "The identifier #{name} does not meet our resource naming convention"    unless good_name name
  raise MissingMD5,  "Missing the Content-MD5 header, required for POSTs to #{this_resource}" unless request_md5
  raise MissingTar,  "#{this_resource} only accepts content types of application/x-tar"       unless request.content_type == 'application/x-tar'

  silo = nil

  PoolReservation.new(request.content_length.to_i) do |silo|
    silo.put(name, request.body, request.content_type || 'application/x-tar')
  end

  computed_md5 = silo.md5(name)

  if computed_md5 != request_md5
    silo.delete(name) if silo.exists?(name)
    raise MD5Mismatch, "The request indicated the MD5 was #{request_md5}, but the server computed #{computed_md5}"
  end

  loc = web_location(silo.filesystem.split('/')[-1], name)

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

