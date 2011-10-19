require 'store/utils'
require 'store/exceptions'
require 'store/silodb'
require 'store/db'

class DateTime
  def to_utc
    new_offset(0).to_s.sub(/\+00:00$/, 'Z')
  end
end

module Store

  # Class PoolFixity
  #
  # TODO: make silo-level fixities use this same strategem, include here.
  #


  # Assemble all the recent fixity data for all silos associated with
  # a given hostname.  Fixity data are returned sorted by package name.

  class PoolFixity

    Struct.new('FixityHeader', :hostname, :count, :earliest, :latest)

    def initialize hostname, port = 80, scheme = 'http'
      @hostname = hostname
      @port     = port.to_i == 80 ? '' : ":#{port}"
      @scheme   = scheme
      @silos    = DB::SiloRecord.all(:hostname => hostname)   # TODO:  adjust when we add 'retired' attribute to silos
      @started  = DateTime.now
    end

    def summary
      Struct::FixityHeader.new(@hostname,
                               Store::DB::PackageRecord.count(:extant => true, :silo_record => @silos),
                               Store::DB::PackageRecord.min(:latest_timestamp, :extant => true, :silo_record => @silos),
                               Store::DB::PackageRecord.max(:latest_timestamp, :extant => true, :silo_record => @silos))
    end



    def url filesystem, name
      @scheme + '://' + @hostname + @port + '/' + filesystem.split('/').pop + '/data/' + name
    end

    def each
      list = Store::DB::PackageRecord.list_all_fixities(@hostname)

      list.each do |pkg|

          # N.B. the following special-casing for the missing case,
          # using nil-valued latest_md5/sha1, is repeated in db.rb and
          # silomixins.rb - all this needs to be refactored into one
          # place and made explicit.

        pkg.location = url(pkg.filesystem, pkg.name)

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

        yield pkg
      end
    end
  end # of class Store::PoolFixity

  # A wrapper for the data returned by the PoolFixity class that can be used in a space-efficient rack response.
  # It returns an XML document with the fixity data provided by a PoolFixity object, a piece at a time.

  class PoolFixityXmlReport

    def initialize hostname, port = 80, scheme = 'http'
      @hostname    = hostname
      @pool_fixity = PoolFixity.new(hostname, port, scheme)
    end

    def each
      header = @pool_fixity.summary

      yield '<fixities hostname="'  + StoreUtils.xml_escape(@hostname) + '" ' +
            'fixity_check_count="'  + header.count.to_s                + '" ' +
         'earliest_fixity_check="'  + header.earliest.to_s             + '" ' +
           'latest_fixity_check="'  + header.latest.to_s               + '">' + "\n"

      @pool_fixity.each do |fix|
        yield  '  <fixity name="'   + StoreUtils.xml_escape(fix.name)     + '" '  +
                     'location="'   + StoreUtils.xml_escape(fix.location) + '" '  +
                         'sha1="'   + fix.latest_sha1                     + '" '  +
                          'md5="'   + fix.latest_md5                      + '" '  +
                         'size="'   + fix.size.to_s                       + '" '  +
                  'fixity_time="'   + fix.latest_timestamp.to_utc         + '" '  +
                     'put_time="'   + fix.initial_timestamp.to_utc        + '" '  +
                       'status="'   + fix.status.to_s                     + '"/>' + "\n"
      end

      yield "</fixities>\n"
    end
  end # of class Store::PoolFixityXmlReport

  # A CSV wrapper for the data returned by the PoolFixity class that can
  # be used in a space-efficient rack response.

  class PoolFixityCsvReport

    def initialize hostname, port = '80', scheme = 'http'
      @pool_fixity = PoolFixity.new(hostname, port, scheme)
    end

    def each
      yield '"name","location","sha1","md5","size","fixity_time","put_time","status"' + "\n"
      @pool_fixity.each do |r|
        yield [r.name, r.location, r.latest_sha1, r.latest_md5, r.size.to_s, r.latest_timestamp.to_utc, r.initial_timestamp.to_utc, r.status.to_s].map{ |e| StoreUtils.csv_escape(e) }.join(',') + "\n"
      end
    end

  end # of class Store::PoolFixityCsvReport
end
