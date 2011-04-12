require 'store/exceptions'
require 'store/silodb'
require 'store/pool'
require 'store/tarreader'
require 'store/utils'
require 'time'
require 'builder'

# TODO: document the site URL structure.
# TODO: recent sinatra fixed relative-redirection problem, check to see if we can remove 'absolutely'

PACKAGES_PER_PAGE = 40 # should be even

include Store

REVISION = Store.version.rev

get '/'       do;    redirect absolutely('/silos/'), 302;  end
get '/silos'  do;    redirect absolutely('/silos/'), 301;  end
get '/silos/' do
  erb :silos, :locals => { :hostname => hostname, :silos => list_silos, :revision => REVISION}
end

# provide information on the services we supply.  There are two requirements: 
#   * a URL that we can POST to: it will return a URL that we can PUT a new resource to store.
#   * one or more URLs where we can retrieve fixity data

get '/services' do
  xml = Builder::XmlMarkup.new(:indent => 2)
  xml.instruct!(:xml, :encoding => 'UTF-8')
  xml.services(:version => Store::VERSION) {
    xml.create(:location => absolutely('/create/%s'),  :method => "post")
    xml.fixity(:location => absolutely('/fixity.csv'), :method => "get",  :mime_type => 'text/csv')
    xml.fixity(:location => absolutely('/fixity.xml'), :method => "get",  :mime_type => 'application/xml')
  }
  status 200
  headers 'Content-Type' => 'application/xml'
  xml.target!
end


# # Provide information about

# get '/silos.xml'  do;
#   text = '<?xml version="1.0" encoding="UTF-8"?>' + "\n"
#   text += '<pool location="' + StoreUtils.xml_escape(this_resource) + '">'
#   list_silos.each do |silo|
#     text += "\n" + '<silo location="' + StoreUtils.xml_escape('http://' + hostname + '/' + silo.name) + '" ' +
#       [:get, :put, :delete, :post].map { |sym| silo.allowed_methods.include?(sym) ? "#{sym}=\"true\"" : "#{sym}=\"false\""  }.join(' ') +
#       " available=\"#{silo.available_space}\"/>"
#   end
#   text += "</pool>\n"
#   content_type 'application/xml'
#   text
# end

get '/:partition/knobs' do |partition|
  redirect absolutely("/#{partition}/knobs/"), 301
end

get '/:partition/knobs/' do |partition|
  silo = get_silo(partition)
  erb :knobs, :locals => { :silo => silo, :methods => methods_hash(silo), :states => states_hash(silo), :revision => REVISION}
end

get '/:partition/data' do |partition|
  redirect absolutely("/#{partition}/data/"), 301
end

get '/:partition/data/' do |partition|
  silo = get_silo(partition)
  silo.get_ok? or raise Http405 

  page   = params[:page].nil?   ?   1   : safe_number(params[:page])
  search = (params[:search].nil? or params[:search] == '') ?  nil : params[:search]

  count      = silo.package_count(search)
  packages   = silo.package_names_by_page(page, PACKAGES_PER_PAGE, search)
  packages_1 = packages[0 .. (PACKAGES_PER_PAGE + 1)/2 - 1]
  packages_2 = packages[(PACKAGES_PER_PAGE + 1)/2 .. packages.count - 1]

  if (packages_2.nil? or packages_2.empty?) and (packages_1.nil? or packages_1.empty?)
    erb_page = :'packages-none-up'
  elsif (packages_2.nil? or packages_2.empty?)
    erb_page = :'packages-one-up'
  else
    erb_page = :'packages-two-up'
  end

  erb erb_page, :locals => { 
    :packages_1      => packages_1,
    :packages_2      => packages_2,
    :hostname        => hostname,
    :silo            => silo,
    :package_count   => count,
    :page            => page,
    :search          => search,
    :number_of_pages => count/PACKAGES_PER_PAGE + (count % PACKAGES_PER_PAGE == 0 ? 0 : 1),
    :revision        => REVISION }
end


# TODO: The send_file lets us set the content-length, but not
# last-modified.  Just using our own class wrapped about a GET works
# but doesn't let us set content-length - might be a chunked issue we
# can work-around by calling proper methods.... or diskstore can set
# the mtime as well on PUT?

get '/:partition/data/:name' do |partition, name|
  silo = get_silo(partition, name)
  silo.get_ok? or raise Http405

  etag silo.etag(name)
  
  headers  'Content-MD5' => StoreUtils.md5hex_to_base64(silo.md5 name), 'Content-Type' => silo.type(name)
  send_file silo.data_path(name), :filename => "#{name}.tar", :type => silo.type(name)
end


get '/:partition/data/:name/' do |partition, name|
  silo = get_silo(partition, name)
  silo.get_ok? or raise Http405

  erb :package, 
  :locals => {
    :hostname => hostname,
    :name     => name,
    :silo     => silo,
    :fixities => silo.fixity_report(name).fixity_records,
    :headers  => Store::TarReader.new(silo.data_path(name)).headers.select { |h| h['type'] != 'directory' }.sort { |a,b| a['filename'].downcase <=> b['filename'].downcase },
    :revision => REVISION
  }
end


get '/:partition/data/:name/*' do |partition, name, path|
  silo = get_silo(partition, name)
  silo.get_ok? or raise Http405                          ### TODO: doesn't seem to work if get disallowed!

  body = filename = nil
  Store::TarReader.new(silo.data_path(name)).each do |tarpath, io|
    if tarpath =~ %r{^[\./]*#{path}$}
      body = io
      filename = tarpath
    end
  end
  
  raise Http404 unless body
  [ 200, { 'Content-Type' => mime_type_by_filename(filename) },  body ]
end

get '/fixity.xml' do
  [ 200, {'Content-Type'  => 'application/xml'}, Store::PoolFixityXmlReport.new(hostname, port) ]
end

get '/fixity.csv' do
  [ 200, {'Content-Type'  => 'text/csv'}, Store::PoolFixityCsvReport.new(hostname, port) ]
end

# implement the above technique for pool/fixity for inidividual silos.

get '/:partition/fixity'  do |partition|
  redirect absolutely("/#{partition}/fixity/"), 301
end

get '/:partition/fixity/' do |partition|
  silo   = get_silo(partition)
  silo.get_ok? or raise Http405

  fixity = silo.fixity_report

  lines = []

  lines.push '<?xml version="1.0" encoding="UTF-8"?>'

  lines.push '<silocheck silo="'  + StoreUtils.xml_escape(fixity.filesystem)   + '" ' +
                        'host="'  + StoreUtils.xml_escape(fixity.hostname)     + '" ' +
          'fixity_check_count="'  + fixity.fixity_check_count.to_s             + '" ' +
          'first_fixity_check="'  + fixity.first_fixity_check.to_s             + '" ' +
           'last_fixity_check="'  + fixity.last_fixity_check.to_s              + '">'

  fixity.fixity_records.each do |r|
    lines.push '  <fixity name="'   + StoreUtils.xml_escape(r[:name]) + '" ' +
                         'sha1="'   + r[:sha1]                        + '" ' +
                          'md5="'   + r[:md5]                         + '" ' +
                         'size="'   + r[:size].to_s                   + '" ' +
                         'time="'   + r[:time].to_s                   + '" ' +
                       'status="'   + r[:status].to_s                 + '"/>'
  end
  
  lines.push "</silocheck>\n"

  content_type 'application/xml'
  lines.join("\n")
end

get '/:partition/fixity/:name' do |partition, name|

  silo = get_silo(partition, name)
  silo.get_ok? or raise Http405 

  fixity = silo.fixity_report(name)

  lines = []

  lines.push '<?xml version="1.0" encoding="UTF-8"?>'

  lines.push '<history   silo="'  + StoreUtils.xml_escape(fixity.filesystem)   + '" ' +
                        'ieid="'  + StoreUtils.xml_escape(name)                + '" ' +
                        'host="'  + StoreUtils.xml_escape(fixity.hostname)     + '" ' +
          'fixity_check_count="'  + fixity.fixity_check_count.to_s             + '" ' +
          'first_fixity_check="'  + fixity.first_fixity_check.to_s             + '" ' +
           'last_fixity_check="'  + fixity.last_fixity_check.to_s              + '">'
  
  # From package level reports we only get information since the last PUT - so there
  # is never a delete record shown this way.
 
  fixity.fixity_records.each do |rec|
    case rec[:action]
    when :fixity
      lines.push "<fixity md5=\"#{rec[:md5]}\" sha1=\"#{rec[:sha1]}\" size=\"#{rec[:size]}\" time=\"#{rec[:time].to_s}\" status=\"#{rec[:status].to_s}\"/>"
    when :put
      lines.push "<put md5=\"#{rec[:md5]}\" sha1=\"#{rec[:sha1]}\" size=\"#{rec[:size]}\" time=\"#{rec[:time].to_s}\"/>"
    end
  end
  lines.push  "</history>\n"

  content_type 'application/xml'
  lines.join("\n") 
end

get '/docs/?' do
  redirect absolutely('/internals/index.html'), 301
end

# TODO: remove
# For investigating sinatra's weird-ass settings defaults..

get '/settings/?' do
  myopts = {}

  [ :app_file, :clean_trace, :dump_errors, :environment, :host, :lock,
    :logging, :method_override, :port, :public, :raise_errors, :root, 
    :run, :server, :sessions, :show_exceptions, :static, :views ].each  do |key|

    if settings.respond_to? key
      value = settings.send key
      rep = value
      if rep.class == Array
        rep = '[' + value.join(', ') + ']'
      elsif rep.class == Symbol
        rep = ':' + value.to_s
      end
      myopts[key] = rep
    else
      myopts[key] = '--'   # undefined
    end
  end
  erb :settings, :locals => { :opts => myopts, :revision => REVISION }
end

# for testing logging, error handling:

get '/oops/?' do
  raise "oops: can't happen"
end

get '/test/?' do
  erb :test, :locals => { :env => @env, :environment => ENV, :revision => REVISION }
end
