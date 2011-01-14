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
    Struct.new('FixityRecord', :name, :status, :md5, :sha1, :time)

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
        yield Struct::FixityRecord.new(rec.name, 
                                       (rec.latest_md5 == rec.initial_md5 and rec.latest_sha1 == rec.initial_sha1) ? :ok : :fail,
                                       rec.latest_md5, 
                                       rec.latest_sha1, 
                                       rec.latest_timestamp)
      end
    end
  end        
end
