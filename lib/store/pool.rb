require 'date'
require 'enumerator'
require 'store/db'
require 'store/exceptions'
require 'store/silodb'
require 'store/utils'
require 'uri'

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
      @base_url = URI.parse(scheme + '://' + hostname + (port.to_i == 80 ? '' : ":#{port}") + '/')
      @silos    = DB::SiloRecord.all(:hostname => hostname, :retired => false)
      @options  = options
    end

    def summary
      conditions = { :extant => true, :silo_record => @silos }
      conditions[:initial_timestamp.lt] = @options[:before] if @options[:before]

      Struct::FixityHeader.new(@base_url.host,
                               Store::DB::PackageRecord.count(conditions),
                               Store::DB::PackageRecord.min(:latest_timestamp, conditions),
                               Store::DB::PackageRecord.max(:latest_timestamp, conditions),
                               (@options[:before] || DateTime.now).to_utc.to_s
                               )
    end


    def list
      return Store::DB::PackageRecord.list_all_fixities(@base_url, @options)
    end

    private

  end # of class Store::PoolFixity

  # A wrapper for the data returned by the PoolFixity class that can be used in a space-efficient rack response.
  # It returns an XML document with the fixity data provided by a PoolFixity object, a piece at a time.

  class PoolFixityXmlReport

    def initialize hostname, port = 80, scheme = 'http', options = {}
      @hostname    = hostname
      @pool_fixity = PoolFixity.new(hostname, port, scheme, options)
      @header      = @pool_fixity.summary
      @list        = @pool_fixity.list
      

    end

    # Ultimately we'll be using this object as the body of a rack responce,
    # which will handle calling each and sending the response to a web client.
    # Here we chunk stuff up - the list returned by @pool_fixity.list is 
    # currently over 300,000 elements, so we need limit the number of yields required..

    def each

      yield '<fixities hostname="'  + StoreUtils.xml_escape(@hostname)             + '" ' +
                 'stored_before="'  + StoreUtils.xml_escape(@header.stored_before) + '" ' +
            'fixity_check_count="'  + @header.count.to_s                           + '" ' +
         'earliest_fixity_check="'  + @header.earliest.to_s                        + '" ' +
           'latest_fixity_check="'  + @header.latest.to_s                          + '">' + "\n"


      @list.each_slice(PoolFixity::CHUNK) do |group|

        text = []
        group.each do |fix|
          text.push '  <fixity name="'   + StoreUtils.xml_escape(fix.name)     + '" '  +
                          'location="'   + StoreUtils.xml_escape(fix.location) + '" '  +
                              'sha1="'   + fix.sha1                            + '" '  +
                               'md5="'   + fix.md5                             + '" '  +
                              'size="'   + fix.size.to_s                       + '" '  +
                       'fixity_time="'   + fix.fixity_time                     + '" '  +
                          'put_time="'   + fix.put_time                        + '" '  +
                            'status="'   + fix.status                          + '"/>'
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
      @list        = @pool_fixity.list
    end

    def to_csv rec
      return  '"' +  rec.name                      +  '",'  + 
              '"' +  rec.location                  +  '",'  + 
              '"' +  rec.sha1                      +  '",'  + 
              '"' +  rec.md5                       +  '",'  + 
              '"' +  rec.size.to_s                 +  '",'  + 
              '"' +  rec.fixity_time               +  '",'  + 
              '"' +  rec.put_time                  +  '",'  + 
              '"' +  rec.status                    +  '"'   
    end

    # Ultimately we'll be using this object as the body of a rack responce,
    # which will handle calling each and sending the response to a web client.
    # Here we chunk stuff up - the list returned by @pool_fixity.list is 
    # currently over 300,000 elements, so we need limit the number of yields required..

    def each

      yield '"name","location","sha1","md5","size","fixity_time","put_time","status"' + "\n"

      @list.each_slice(PoolFixity::CHUNK) do |group|
        yield group.map { |rec| to_csv(rec) }.join("\n") + "\n"
      end
    end

  end # of class Store::PoolFixityCsvReport

end # of module Store
