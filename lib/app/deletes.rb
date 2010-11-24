# TODO: redirect users to an https address that requires authentication

delete '/:partition/data/:name' do |partition, name|
  silo = get_silo(partition, name)
  silo.delete_ok? or raise Http405
  silo.delete(name)
  status 204
end
