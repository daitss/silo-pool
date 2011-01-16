require 'store/utils'
require 'store/exceptions'
require 'store/silodb'
require 'store/db'

module Store

# Class PoolFixity
#
# TODO: make silo fixities use this same strategem
#

  class PoolFixity

    Struct.new('FixityHeader', :hostname, :count, :earliest, :latest)
    Struct.new('FixityRecord', :silo, :name, :status, :md5, :sha1, :time)

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

    def each
      Store::DB::PackageRecord.all(:order => [ :name.asc ], :extant => true, :silo_record => @silos).each do |rec|
        yield Struct::FixityRecord.new(rec.silo_record.short_name,
                                       rec.name, 
                                       (rec.latest_md5 == rec.initial_md5 and rec.latest_sha1 == rec.initial_sha1) ? :ok : :fail,
                                       rec.latest_md5, 
                                       rec.latest_sha1, 
                                       rec.latest_timestamp)
      end
    end
  end # of class PoolFixity

  # A wrapper for the above that can be used as a rack response with each method; it returns an
  # xml representation of the above

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
        yield  '  <fixity name="'   + StoreUtils.xml_escape(fix.name) + '" '  +
                         'silo="'   + StoreUtils.xml_escape(fix.silo) + '" '  +                         
                         'sha1="'   + fix.sha1                        + '" '  +
                          'md5="'   + fix.md5                         + '" '  +
                         'time="'   + fix.time.to_s                   + '" '  +
                       'status="'   + fix.status.to_s                 + '"/>' + "\n"
      end

      yield "</fixities>\n"
    end
  end # of class PoolFixityXmlReport


  class PoolFixityCsvReport
    include Enumerable

    @pool_fixity = nil
    @hostname    = nil

    def initialize hostname
      @hostname    = hostname
      @pool_fixity = PoolFixity.new(hostname)
    end

    def each
      header = @pool_fixity.summary

      yield "name,host,silo,sha1,md5,time,status\n"

      @pool_fixity.each do |fix|
        yield [fix.name, @hostname, fix.silo, fix.sha1, fix.md5, fix.time.to_s, fix.status.to_s].join(',') + "\n"
      end
    end

  end # of class PoolFixityCsvReport
end
