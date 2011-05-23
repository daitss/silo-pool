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

    CHUNK_SIZE = 2000

    Struct.new('FixityHeader', :hostname, :count, :earliest, :latest)
    Struct.new('FixityRecord', :name, :location, :status, :md5, :sha1, :fixity_time, :put_time, :size)

    include Enumerable

    @hostname = nil
    @silos    = nil
    @port     = nil
    @scheme   = nil
    @started  = nil

    def initialize hostname, port = 80, scheme = 'http'
      @hostname = hostname
      @port     = port
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

    # There's too much data to get all of the packages at once;
    # chunking it in sizes of 2000 records was an order of magnitude
    # faster (but it's still pretty slow, partially due to
    # datamapper's casting of the timestamps to DateTime, which we
    # really don't need - a string straight out of the database would
    # be better for our needs).

    # At the time of this writing, we have 1/4 million records, so
    # 2000 gives us 125 or so separate database hits.

    def package_chunks
      size   = CHUNK_SIZE
      offset = 0
      while (records = Store::DB::PackageRecord.all(
                                                    :order => [ :name.asc ],
                                                    :initial_timestamp.lt => @started, # stop newly-arrived randomly-named packages 'slipping in' and causing apparent doubly-listed packages
                                                    :silo_record => @silos
                                                    ).slice(offset, size)).length > 0  do
        offset += size
        yield records
      end
    end

    def each
      package_chunks do |packages|  # get each sublist (of CHUNK_SIZE)        
        packages.each do |pkg|      # and process it

          next unless pkg.extant    # We used to place ':extant => true' in the DB query, but we need to
                                    # preserve the entire package list to avoid a package being dropped
                                    # out from a sublist when a delete to a prior pakage occurs before that
                                    # next sublist is generated.  We use a timestamp in the above list to 
                                    # avoid the converse case, a package insert.

          #  StructFixityRecord is ordered as:  name, location, status, md5, sha1, fixity_time, put_time, size

          yield Struct::FixityRecord.new(pkg.name,
                                         pkg.url(@port, @scheme),
                                         (pkg.latest_md5 == pkg.initial_md5 and pkg.latest_sha1 == pkg.initial_sha1) ? :ok : :fail,
                                         pkg.latest_md5,
                                         pkg.latest_sha1,
                                         pkg.latest_timestamp,
                                         pkg.initial_timestamp,
                                         pkg.size
                                         )
        end
      end
    end
  end # of class Store::PoolFixity

  # A wrapper for the data returned by the PoolFixity class that can be used in a space-efficient rack response.
  # It returns an XML document with the fixity data provided by a PoolFixity object, a piece at a time.

  class PoolFixityXmlReport
    include Enumerable

    @pool_fixity = nil
    @hostname    = nil

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
                         'sha1="'   + fix.sha1                            + '" '  +
                          'md5="'   + fix.md5                             + '" '  +
                         'size="'   + fix.size.to_s                       + '" '  +
                  'fixity_time="'   + fix.fixity_time.to_utc              + '" '  +
                     'put_time="'   + fix.put_time.to_utc                 + '" '  +
                       'status="'   + fix.status.to_s                     + '"/>' + "\n"
      end

      yield "</fixities>\n"
    end
  end # of class Store::PoolFixityXmlReport

  # A CSV wrapper for the data returned by the PoolFixity class that can
  # be used in a space-efficient rack response.

  class PoolFixityCsvReport
    include Enumerable

    @pool_fixity = nil

    def initialize hostname, port = '80', scheme = 'http'
      @pool_fixity = PoolFixity.new(hostname, port, scheme)
    end

    def each
      yield '"name","location","sha1","md5","size","fixity_time","put_time","status"' + "\n"
      @pool_fixity.each do |r|
        yield [r.name, r.location, r.sha1, r.md5, r.size.to_s, r.fixity_time.to_utc, r.put_time.to_utc, r.status.to_s].map{ |e| StoreUtils.csv_escape(e) }.join(',') + "\n"
      end
    end

  end # of class Store::PoolFixityCsvReport
end
