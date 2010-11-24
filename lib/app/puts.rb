require 'store/silodb'
require 'store/exceptions'
require 'store/utils'
require 'time'
require 'builder'

include Store

# TODO: modify daitss 1.5 to supply mime-type application/x-tar, and require that it be set here.

put '/:partition/data/:name' do |partition, name|

  silo = get_silo(partition)
  silo.put_ok? or raise Http405 

  raise Http403, "The resource #{web_location(partition, name)} already exists; delete it first" if silo.exists? name
  
  supplied_md5 = request_md5()
  
  raise Http412, "The identifier #{name} does not meet the resource naming convention for #{web_location(partition)}" unless good_name name
  raise Http412, "Missing the Content-MD5 header, required for PUTs to #{web_location(partition)}" unless supplied_md5

  ## TODO: check, is a silo cleanup necessary her?

  data = request.body                                          # singleton method to provide content length. (silo.put needs
  eval "def data.size; #{request.content_length.to_i}; end"    # to garner size; but that's not provided by 'rewindable' body object)
  silo.put(name, data, request.content_type || 'application/x-tar')
  computed_md5 = silo.md5(name)

  if computed_md5 != supplied_md5
    silo.delete(name) if silo.exists?(name)
    raise Http412, "The request indicated the MD5 was #{supplied_md5}, but the server computed #{computed_md5}"
  end

  status 201
  headers 'Location' => web_location(partition, name), 'Content-Type' => 'application/xml'

  xml = Builder::XmlMarkup.new(:indent => 2)
  xml.instruct!(:xml, :encoding => 'UTF-8')
  xml.created(:name     => name,
              :etag     => silo.etag(name),
              :md5      => silo.md5(name),
              :sha1     => silo.sha1(name),
              :size     => silo.size(name),
              :type     => silo.type(name),
              :time     => silo.datetime(name).to_s,
              :location => web_location(partition, name))
  xml.target!
end
