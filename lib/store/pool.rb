require 'store/utils'
require 'store/exceptions'
require 'store/silodb'
require 'store/db'

module Store

# Class PoolFixity
#
# TODO: make silo-level fixities use this same strategem, include here.
#

  # Assemble all the recent fixity data for all silos associated with
  # a given hostname.  Fixity data are returned sorted by package name.

  class PoolFixity

    Struct.new('FixityHeader', :hostname, :count, :earliest, :latest)
    Struct.new('FixityRecord', :name, :location, :status, :md5, :sha1, :time, :size)

    include Enumerable

    @hostname = nil
    @silos    = nil

    def initialize hostname
      @hostname = hostname
      @silos = DB::SiloRecord.all(:hostname => hostname)
    end

    def summary
      Struct::FixityHeader.new(@hostname,
                               Store::DB::PackageRecord.count(:extant => true, :silo_record => @silos),
                               Store::DB::PackageRecord.min(:latest_timestamp, :extant => true, :silo_record => @silos),
                               Store::DB::PackageRecord.max(:latest_timestamp, :extant => true, :silo_record => @silos))
    end

    # There's too much data to get all of the packages at once;
    # chunking it in sizes of 2000 records is an order of magnitude
    # faster (but it's still pretty slow due to datamapper's casting
    # of the timestamps to DateTime, which we really don't need - a
    # string straight out of the database would be better for our
    # needs).

    # TODO: try doing tests with different sizes to determine the
    # sweet spot. Currently we have 1/4 million records, so 2000 gives
    # us 125 or so separate database hits.

    def package_chunks
      size   = 2000
      offset = 0
      while (records = Store::DB::PackageRecord.all(:order => [ :name.asc ], :extant => true, :silo_record => @silos).slice(offset, size)).length > 0  do
        offset += size
        yield records
      end
    end

    def each
      package_chunks do |packages|
        packages.each do |pkg|
          yield Struct::FixityRecord.new(pkg.name,
                                         pkg.url,
                                         (pkg.latest_md5 == pkg.initial_md5 and pkg.latest_sha1 == pkg.initial_sha1) ? :ok : :fail,
                                         pkg.latest_md5,
                                         pkg.latest_sha1,
                                         pkg.latest_timestamp,
                                         pkg.size
                                         )
        end
      end
    end
  end # of class PoolFixity


  # A wrapper for the data returned by the PoolFixity class that can be used in a space-efficient rack response.
  # It returns an XML document with the fixity data provided by a PoolFixity object.

  class PoolFixityXmlReport
    include Enumerable

    @pool_fixity = nil
    @hostname    = nil

    def initialize hostname
      @hostname    = hostname
      @pool_fixity = PoolFixity.new(hostname)
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
                         'sha1="'   + fix.sha1                            + '" '  +
                          'md5="'   + fix.md5                             + '" '  +
                         'size="'   + fix.size.to_s                       + '" '  +
                         'time="'   + fix.time.to_s                       + '" '  +
                       'status="'   + fix.status.to_s                     + '"/>' + "\n"
      end

      yield "</fixities>\n"
    end
  end # of class PoolFixityXmlReport


  # A wrapper for the data returned by the PoolFixity class that can be used in a space-efficient rack response.
  # It returns a CSV document with the fixity data provided by a PoolFixity object.

  class PoolFixityCsvReport
    include Enumerable

    @pool_fixity = nil

    def initialize hostname
      @pool_fixity = PoolFixity.new(hostname)
    end

    def each
      yield '"name","location","sha1","md5","size","time","status"' + "\n"
      @pool_fixity.each do |r|
        yield [r.name, r.location, r.sha1, r.md5, r.size.to_s, r.time.to_s, r.status.to_s].map{ |e| StoreUtils.csv_escape(e) }.join(',') + "\n"
      end
    end

  end # of class PoolFixityCsvReport
end
