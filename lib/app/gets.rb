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
  erb :silos, :locals => { 
    :stale_days => settings.fixity_stale_days,
    :expired_days => settings.fixity_expired_days,
    :credentials => DB::Authentication.lookup('admin'), 
    :hostname => hostname, 
    :silos => list_silos, 
    :revision => REVISION
  }
end

get '/credentials?' do
  erb :credentials, :locals => { :credentials => DB::Authentication.lookup('admin'), :hostname => hostname, :revision => REVISION}
end

get '/add-silo?' do
  erb :add, :locals => {:hostname => hostname, :revision => REVISION}
end


# Provide information on the services we supply.  There are two requirements that a storage master
# requires in the returned XML:
#
#   * a create tag showing a URL that we can POST to: it will return a URL that we can PUT a new resource to store
#   * a fixity tag showing one or more URLs where we can retrieve fixity data
#
# TODO: to be RESTful, this should return a specialized media-type.

get '/services' do
  xml = Builder::XmlMarkup.new(:indent => 2)
  xml.instruct!(:xml, :encoding => 'UTF-8')

  xml.services(:version => Store::VERSION) {
    xml.create(:location => absolutely('/create/%s'),  :method => "post")
    xml.fixity(:location => absolutely('/fixity.csv'), :method => "get",  :mime_type => 'text/csv')
    xml.fixity(:location => absolutely('/fixity.xml'), :method => "get",  :mime_type => 'application/xml')

    list_silos.each do |silo|
      xml.partition_fixity(:localtion => absolutely("/#{silo.name}/fixity/"), :method => "get",  :mime_type => 'application/xml')
    end

    list_silos.each do |silo|
      xml.store(:location => absolutely("/#{silo.name}/data/%s"),  :method => "put")
    end

    list_silos.each do |silo|
      xml.retrieve(:location => absolutely("/#{silo.name}/data/%s"),  :method => "get")
    end

  }
  status 200
  headers 'Content-Type' => 'application/xml'
  xml.target!
end


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



get '/:partition/data/:name' do |partition, name|
  silo = get_silo(partition, name)
  silo.get_ok? or raise Http405

  etag silo.etag(name)
  
  headers  'Content-MD5' => StoreUtils.md5hex_to_base64(silo.md5 name), 'Content-Type' => silo.type(name), 'Last-Modified' => Time.parse(silo.datetime(name).to_s).httpdate
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
  silo.get_ok? or raise Http405

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
  options = {}
  options[:stored_before] ||= stored_before?

  [ 200, {'Content-Type'  => 'application/xml'}, Store::PoolFixityXmlReport.new(hostname, port, request.scheme, options) ]
end

get '/fixity.csv' do
  options = {}
  options[:stored_before] ||= stored_before?    

  [ 200, {'Content-Type'  => 'text/csv'}, Store::PoolFixityCsvReport.new(hostname, port, request.scheme, options) ]
end

# TODO:  refactor individual silo fixities to use the above xml/csv report techniques.

get '/:partition/fixity'  do |partition|
  redirect absolutely("/#{partition}/fixity/"), 301
end

get '/:partition/fixity/' do |partition|
  silo   = get_silo(partition)

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

  fixity = silo.fixity_report(name)

  lines = []

  lines.push '<?xml version="1.0" encoding="UTF-8"?>'

  lines.push '<history   silo="'  + StoreUtils.xml_escape(fixity.filesystem)   + '" ' +
                        'ieid="'  + StoreUtils.xml_escape(name)                + '" ' +
                        'host="'  + StoreUtils.xml_escape(fixity.hostname)     + '" ' +
          'fixity_check_count="'  + fixity.fixity_check_count.to_s             + '" ' +
          'first_fixity_check="'  + fixity.first_fixity_check.to_s             + '" ' +
           'last_fixity_check="'  + fixity.last_fixity_check.to_s              + '">'
  
  # From package level reports we only get information since the last
  # PUT - so there is never a delete record shown this way.  Also,
  # currently :missing won't show since we ge an error exception.
 
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


get '/status' do
  [ 200, {'Content-Type'  => 'application/xml'}, "<status/>\n" ]
end


# for testing logging, error handling:

get '/oops/?' do
  raise "oops: can't happen"
end

get '/test/?' do
  erb :test, :locals => { :env => @env, :environment => ENV, :revision => REVISION }
end
