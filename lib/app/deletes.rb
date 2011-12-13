delete '/:partition/data/:name' do |partition, name|
  silo = get_silo(partition, name)
  silo.delete_ok? or raise(Http405, "DELETEs are not currently allowed on silo #{partition} - you must enable them to delete #{name}")
  silo.delete(name)
  status 204
end
