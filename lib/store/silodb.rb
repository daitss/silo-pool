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

    def missing name
      DB::HistoryRecord.missing(silo_record, name)
    end

    # exists? does more than simply checks if a package exists on disk/tape - it
    # raises exceptions if the db/filesystem is inconsistent.

    def exists? name
      on_disk = super name

      rec = DB::PackageRecord.lookup(silo_record, name)

      # Let's check for potential problems with a missing DB record

      # This is an alien package; we'll rarely find alien packages by iterating through each, by the way.

      if on_disk and rec.nil?
        raise AlienPackage, "Alien package #{name}: database/disk inconsistency on #{hostname}:#{filesystem} - package found on disk, but never recorded in silo db"
      end

      # The case of some random name we're being queried for that we've never, ever, heard of.

      if not on_disk and rec.nil?
        return false
      end

      # Now we take care of cases were the record exists in the DB, so we check consistency against the file system.
      #
      # There are four cases (extant: t/f) * (on_disk: t/f);

      case

      when (on_disk and rec.extant):
        return true

      when (on_disk and not rec.extant):
        raise GhostPackage, "Ghost package #{name}: database/disk inconsistency on #{hostname}:#{filesystem}: the silo db says package should not be on disk, but it's still there"

      when (not on_disk and rec.extant):
        raise MissingPackage, "Missing package #{name}: database/disk inconsistency on #{hostname}:#{filesystem}: the silo db says package should be on disk, but it's not"

      when (not on_disk and not rec.extant):
        return false
      end
      

      raise "exists? somehow missed a test condition for #{name} on #{hostname}:#{filesystem}: DB record is '#{rec.inspect}'"
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
