require 'time'
require 'digest/md5'
require 'net/http'
require 'uri'
require 'tempfile'
require 'tmpdir'
require 'fileutils'



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

  def delete package
    uri = URI.parse(File.join(location, package.name))

    Net::HTTP.start(uri.host, uri.port) do |http|
      http.read_timeout = 10
      response = http.send_request('DELETE', uri.request_uri)
      return response
    end
  end

  def get package
    uri = URI.parse(File.join(location, package.name))

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
