require 'date'
require 'enumerator'
require 'store/db'
require 'store/exceptions'
require 'store/silodb'
require 'store/utils'

class DateTime
  def to_utc
    new_offset(0).to_s.sub(/\+00:00$/, 'Z')
  end
end

module Store

  # Class PoolFixity
  #
  # TODO: make silo-level fixity reports use this same strategem and include here

  # Assemble all the recent fixity data for all silos associated with
  # a given hostname.  Fixity data are returned sorted by package name.

  class PoolFixity

    CHUNK = 1000

    Struct.new('FixityHeader', :hostname, :count, :earliest, :latest, :stored_before)

    # only option supported is :before, which should be a DateTime object

    def initialize hostname, port = 80, scheme = 'http', options = {}
      @hostname = hostname
      @port     = port.to_i == 80 ? '' : ":#{port}"
      @scheme   = scheme
      @silos    = DB::SiloRecord.all(:hostname => hostname, :retired => false)
      @options  = options
    end

    def summary

      conditions = { :extant => true, :silo_record => @silos }
      conditions[:initial_timestamp.lt] = @options[:before] if @options[:before]

      Struct::FixityHeader.new(@hostname,
                               Store::DB::PackageRecord.count(conditions),
                               Store::DB::PackageRecord.min(:latest_timestamp, conditions),
                               Store::DB::PackageRecord.max(:latest_timestamp, conditions),
                               (@options[:before] || DateTime.now).to_utc.to_s
                               )

    end


    def list
      start = Time.now

      list = Store::DB::PackageRecord.list_all_fixities(@hostname, @options)
      list.each  { |pkg| update_record(pkg) }

      STDERR.puts sprintf("FixityReport: got %d records in %d seconds", list.length, (Time.now - start).to_i)
      return list
    end

    private

    def url filesystem, name
      @scheme + '://' + @hostname + @port + '/' + filesystem.split('/').pop + '/data/' + name
    end

    # update_record(pkg)
    #
    # ultimately, pkg is from datamapper that has left some place holders for us to fill in,
    # and here we do just that.
    #
    # fields from database:
    #
    # packages.initial_md5
    # packages.initial_sha1
    # packages.initial_timestamp
    # packages.latest_md5 (may be nil-valued)
    # packages.latest_sha1 (may be nil-valued)
    # packages.latest_timestamp
    # packages.name
    # packages.size
    # silos.filesystem
    # location (nil => url string)
    # status (nil => one of :missing, :fail, :ok)

    def update_record pkg
      pkg.location = url(pkg.filesystem, pkg.name)

      # N.B. the following test for the missing case,
      # using nil-valued latest_md5/sha1; is repeated in db.rb and
      # silomixins.rb - all this needs to be refactored into one
      # place and made explicit.

      case
      when (pkg.latest_md5 == pkg.initial_md5 and pkg.latest_sha1 == pkg.initial_sha1) then
        pkg.status = :ok
      when (pkg.latest_md5.nil? and pkg.latest_sha1.nil?) then
        pkg.latest_md5  = ''
        pkg.latest_sha1 = ''
        pkg.status = :missing
        pkg.size   = 0
      else
        pkg.status = :fail
      end
    end



  end # of class Store::PoolFixity

  # A wrapper for the data returned by the PoolFixity class that can be used in a space-efficient rack response.
  # It returns an XML document with the fixity data provided by a PoolFixity object, a piece at a time.

  class PoolFixityXmlReport

    def initialize hostname, port = 80, scheme = 'http', options = {}
      @hostname    = hostname
      @pool_fixity = PoolFixity.new(hostname, port, scheme, options)
    end

    # Ultimately we'll be using this object as the body of a rack responce,
    # which will handle calling each and sending the response to a web client.
    # Here we chunk stuff up - the list returned by @pool_fixity.list is 
    # currently over 300,000 elements, so we need limit the number of yields required..

    def each
      @header ||= @pool_fixity.summary

      yield '<fixities hostname="'  + StoreUtils.xml_escape(@hostname)             + '" ' +
                 'stored_before="'  + StoreUtils.xml_escape(@header.stored_before) + '" ' +
            'fixity_check_count="'  + @header.count.to_s                           + '" ' +
         'earliest_fixity_check="'  + @header.earliest.to_s                        + '" ' +
           'latest_fixity_check="'  + @header.latest.to_s                          + '">' + "\n"

      @list ||= @pool_fixity.list

      @list.each_slice(PoolFixity::CHUNK) do |group|

        text = []
        group.each do |fix|
          text.push '  <fixity name="'   + StoreUtils.xml_escape(fix.name)     + '" '  +
                          'location="'   + StoreUtils.xml_escape(fix.location) + '" '  +
                              'sha1="'   + fix.latest_sha1                     + '" '  +
                               'md5="'   + fix.latest_md5                      + '" '  +
                              'size="'   + fix.size.to_s                       + '" '  +
                       'fixity_time="'   + fix.latest_timestamp.to_utc         + '" '  +
                          'put_time="'   + fix.initial_timestamp.to_utc        + '" '  +
                            'status="'   + fix.status.to_s                     + '"/>'
        end
        yield text.join("\n") + "\n"
      end
      yield "</fixities>\n"
    end

  end # of class Store::PoolFixityXmlReport

  # A CSV wrapper for the data returned by the PoolFixity class that can
  # be used in a space-efficient rack response.

  class PoolFixityCsvReport

    def initialize hostname, port = '80', scheme = 'http', options = {}
      @pool_fixity = PoolFixity.new(hostname, port, scheme, options)
    end

    # Ultimately we'll be using this object as the body of a rack responce,
    # which will handle calling each and sending the response to a web client.
    # Here we chunk stuff up - the list returned by @pool_fixity.list is 
    # currently over 300,000 elements, so we need limit the number of yields required..

    def each
      yield '"name","location","sha1","md5","size","fixity_time","put_time","status"' + "\n"
      @list ||= @pool_fixity.list

      @list.each_slice(PoolFixity::CHUNK) do |group|
        text = []
        group.each do |r|
          text.push [r.name, r.location, r.latest_sha1, r.latest_md5, r.size.to_s, r.latest_timestamp.to_utc, r.initial_timestamp.to_utc, r.status.to_s].map{ |e| StoreUtils.csv_escape(e) }.join(',')
        end
        yield text.join("\n") + "\n"
      end
    end

  end # of class Store::PoolFixityCsvReport
end
