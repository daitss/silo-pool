require 'time'
require 'digest/md5'
require 'net/http'
require 'uri'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require 'xml'
require 'uri'

# Create a new package with optional size
#
#   package = Package.new
#
#   package.name
#   package.data
#   package.size
#   package.md5

class Package

  attr_reader :name, :md5, :path, :size

  def initialize size = nil
    @name    =   'E' + Time.now.strftime("%Y%m%d") + '_' +  sequence
    @path    = "/tmp/" + @name
    open(path, "w") { |f| f.puts rand(10000000000).to_s + "\n" }    
    @md5 = Digest::MD5.hexdigest(File.read path)
    @size = File.stat(path).size
  end

  def data
    File.read(path)
  end

  def delete
    FileUtils.rm_f @path
  end
    
  private

  # Generate a six-character sequence from AAAAAA to ZZZZZZ using the time of day.

  def sequence
    time = DateTime.now
    
    point_of_day = time.sec_fraction.to_f  + ((time.hour * 60 + time.min) * 60 + time.sec)/86_400.0
    seq = (point_of_day * 308_915_776).to_i  # Our place in the possible sequences AAAAAA..ZZZZZZ    

    letters = ''

    (1..6).each do |n|
      letters += (('A'..'Z').to_a[seq % 26])
      seq /= 26
    end    

    letters
  end
end
  


class Client
  attr_reader :location

  def initialize location
    @location = location
  end

  def put package
    uri = URI.parse(File.join(location, package.name))

    Net::HTTP.start(uri.host, uri.port) do |http|
      http.read_timeout = 30
      headers = { 
        'Content-MD5'    => md5_to_base64(package.md5),
        'Content-Type'   => 'application/x-tar',
      } 

      return http.send_request('PUT', uri.request_uri, package.data, headers)
    end
  end


  def post package
    uri = URI.parse(location)

    Net::HTTP.start(uri.host, uri.port) do |http|
      http.read_timeout = 30
      headers = { 
        'Content-MD5'    => md5_to_base64(package.md5),
        'Content-Type'   => 'application/x-tar',
      } 
      return http.send_request('POST', uri.request_uri, package.data, headers)
    end
  end

  def delete package = nil

    if package
      uri = URI.parse(File.join(location, package.name))
    else
      uri = URI.parse(location)
    end

    Net::HTTP.start(uri.host, uri.port) do |http|
      http.read_timeout = 10
      response = http.send_request('DELETE', uri.request_uri)
      return response
    end
  end


  def get package = nil
    if package
      uri = URI.parse(File.join(location, package.name))
    else
      uri = URI.parse(location)
    end

    Net::HTTP.start(uri.host, uri.port) do |http|
      http.read_timeout = 10
      return http.send_request('GET', uri.request_uri)
    end
  end



  private

  # On PUTs we are required to add Content-MD5 => <encoded md5>.
  # This method base64 encodes an MD5 hexstring 

  def md5_to_base64 hexdigest
    [hexdigest.scan(/../).pack("H2" * 16)].pack("m").chomp
  end

end


# parse_service_doc gets something like:
#
# <?xml version=1.0 encoding=UTF-8?>
# <services version=1.0.0>
#   <create method=post location="http://pool.a.local/create/%s/">
#   <fixity method=get mime_type="text/csv" location="http://pool.a.local/fixity.csv" />
#   <fixity method=get mime_type="application/xml" location="http://pool.a.local/fixity.xml" />
# </services>
#
# and returns the create method's location

def parse_service_document text
  parser = XML::Parser.string(text).parse
  node  = parser.find('create')[0]
  return node['location']
end


# parse_creation_document should get something like:
#
# <?xml version="1.0" encoding="UTF-8"?>
# <created type="application/x-tar" time="2011-05-12T17:53:10-04:00" sha1="c967c2a93e61f69f0aec7ddc3536207d5edfee9b" size="11" location="http://pool.a.local/silo-pool.a.1/data/E20110512_BXQUJT" name="E20110512_BXQUJT" etag="515ca4dda5a09cf739edb96977ffbf3e" md5="19b4f7b8d6eed8a226a51970768d0c22"/>


def parse_creation_document text
  parser = XML::Parser.string(text).parse
  node  = parser.find('/created')[0]
  return node['location']
end


def create_ieid
  range = 26 ** 6
  sleep (60.0 * 60.0 * 24.0) / range   # make sure we're unique, and we pause

  now  = Time.now
  mid  = Time.mktime(now.year.to_s, now.month.to_s, now.day.to_s)
  point_in_day  = ((now.to_i - mid.to_i) + now.usec/1_000_000.0) / 86400.0  # fraction of day to microsecond resolution
  point_in_ieid = (point_in_day * range).to_i    # fraction of day in fixed point, base 26: 'AAAAAA' .. 'ZZZZZZ'

  # horner's algorithm on point_in_ieid

  letters = ('A'..'Z').to_a
  frac = ''
  6.times do |i|
    point_in_ieid, rem = point_in_ieid / 26, point_in_ieid % 26
    frac += letters[rem]
  end
  return sprintf('E%04d%02d%02d_%s', now.year, now.month, now.day, frac.reverse)
end

