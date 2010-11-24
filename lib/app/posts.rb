

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


post '/:partition/knobs/allowed-states' do |partition|

  silo      = get_silo(partition)
  new_state = text_to_state(params[:state])

  Logger.warn "Request from #{@env['REMOTE_ADDR']} to change state of #{silo.filesystem} from #{state_to_text(silo.state)} to #{state_to_text(new_state)}."

  silo.state new_state if silo.state != new_state
  redirect absolutely("/silos/")
end

