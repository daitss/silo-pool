require 'ostruct'
require 'socket'
require 'store/db'
require 'store/exceptions'
require 'store/silo'
require 'store/silomixins'
require 'store/utils'
require 'time'

module Store
  class SiloDB < Silo

    include Fixity
    include SiloMixinMethods

    attr_reader :silo_record, :hostname, :filesystem

    ## TODO:  this returns all silos, including tape-based ones.  That's just dumb.
    
    def initialize(hostname, filesystem)
      @hostname    = hostname.downcase
      @filesystem  = filesystem.sub(%r{/+$}, '')
      @silo_record = DB::SiloRecord.lookup(hostname, filesystem) ### or DB::SiloRecord.create(hostname, filesystem)
      super filesystem
    end


    def self.create(hostname, filesystem)
      filesystem = filesystem.sub(%r{/+$}, '')
      raise "Silo create: filesystem #{filesystem} does not exist" unless File.directory? filesystem
      DB::SiloRecord.create hostname, filesystem
    end

    def self.silos hostname
      DB::SiloRecord.list hostname
    end

    def self.hosts
      list = {}
      DB::SiloRecord.list.each { |rec| list[rec.hostname] = true }
      list.keys.sort
    end

    def available_space
      return 0 unless File.exists? filesystem
      return StoreUtils.disk_free filesystem
    end


    def to_s
      "#<SiloDB: #{self.hostname}:#{self.filesystem}>"
    end

    # Organize exceptions and report potential orphans.

    #### TODO: bug here. Need to unsnarl puts on failed DB

    def put name, data, type=nil
      type ||= 'application/octet-stream'
      super name, data, type
      rec =  { :md5 => md5(name), :sha1 => sha1(name), :type => type(name), :timestamp => datetime(name), :size => size(name) }
      DB::HistoryRecord.put(silo_record, name, rec)

    end

    def delete name      
      super name
      DB::HistoryRecord.delete(silo_record, name)
    end

    def fixity name, options
      DB::HistoryRecord.fixity(silo_record, name, options)
    end

    def exists? name
      on_disk = super name
      rec = DB::PackageRecord.lookup(silo_record, name)
      in_db = (rec.nil? ? false : rec.extant)
      raise "database/disk inconsistency on #{hostname}:#{filesystem} discovered when running exists?(#{name}): it is #{on_disk ? 'on' : 'not on'} disk, but database says it #{in_db ? 'should' : 'should not'} be." if in_db != on_disk
      on_disk
    end

    # TODO, perhaps:
    #
    # Change to raise error if silo doesn't exist -- you have to be prepared for it when using.
    #
    # silodb.each do |name| 
    #   begin
    #     <do something with name...>
    #   rescue => e                     # we should have 'missing data' exception
    #     <recover nicely>
    #   end
    # end

    def each
      DB::PackageRecord.list(silo_record, :extant => true).each { |rec| yield rec.name }
    end

    # TODO: refactor so above does below:

    def each_package_record
      DB::PackageRecord.list(silo_record, :extant => true).each { |rec| yield rec }
    end

    # see silomixins.rb for *_fixity_report methods

    def fixity_report name = nil
      if name
        package_fixity_report name
      else
        silo_fixity_report
      end
    end

  end # of class SiloDB
end # of module Store
