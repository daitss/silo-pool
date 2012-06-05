require 'fileutils'
require 'ostruct'
require 'socket'
require 'store/db'
require 'store/exceptions'
require 'store/silo'
require 'store/silomixins'
require 'store/tsmexecutor'
require 'store/utils'
require 'time'

# TODO:  inject a logger here, and if set, use it for getting the TSM outputs.

module Store

  class SiloTape

    include Fixity
    include SiloMixinMethods

    DAYS_TO_CACHE = 2   # how long we should keep retrieved packages around (silo.delete will clear cache as well)

    attr_reader :hostname, :filesystem, :silo_record, :cache_silo, :tivoli_server

    def self.setup(config_file, key)
      DB.setup(config_file, key)
    end

    def self.create(hostname, filesystem)
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

    def initialize(hostname, filesystem, cache_root, tivoli_server)

      if not File.directory? cache_root
        raise ConfigurationError, "Cache directory #{cache_root} is not a directory." 
      end
     
      if not File.writable?  cache_root
        raise ConfigurationError, "Cache directory #{cache_root} is owned by #{StoreUtils.user(cache_root)} and is not writable by this process, which is running as user #{StoreUtils.user}."
      end
      @hostname      = hostname.downcase
      @filesystem    = filesystem.gsub(%r{/+$}, '')
      @tivoli_server = tivoli_server
      @silo_record   = DB::SiloRecord.lookup hostname, filesystem
#STDERR.puts "silotape hostname="<<@hostname <<" filesystem="<<@filesystem<<" tivoli_server="<<@tivoli_server<<" silo_record="<<@silo_record
      raise ConfigurationError, "No database record found for tape-based silo #{hostname}:#{filesystem}." unless @silo_record

      # TODO: would be better to be lazy here and make them at need:

      dir = File.join(cache_root, 'tape-silo-cache-' + Digest::MD5.hexdigest(hostname + filesystem)[0..7])  # don't want a collison from same package on two silos
      FileUtils.mkdir_p dir

      @cache_silo  = Silo.new(dir)

      readme = File.join(dir, 'ReadMe')
      if (not File.exists?(readme)) and File.writable?(dir)
        File.open(readme, 'w') { |fh| fh.puts "This is the cache directory for the tape-based silo #{hostname}:#{filesystem}." }
      end
    end

    def to_s
      "#<SiloTape: #{self.hostname}:#{self.filesystem} (#{cache_silo})>"
    end

    def available_space
      0
    end

    def put name, data, type = nil
      raise Http405, "PUTs are never allowed for the tape-baed silo #{self}"
    end

    def etag(name)
      Digest::MD5.hexdigest(name + md5(name))
    end
    
    def each
      DB::PackageRecord.list(silo_record, :extant => true).each { |rec| yield rec.name }
    end

    def exists?  name
      rec = DB::PackageRecord.lookup(silo_record, name)
      rec.nil? ? false : rec.extant
    end

    def deleted? name
      rec = DB::PackageRecord.lookup(silo_record, name)
      rec.nil? ? false : rec.extant == false
    end

    def size name;     package_rec = lookup! name;  package_rec.size;              end
    def type name;     package_rec = lookup! name;  package_rec.type;              end
    def md5 name;      package_rec = lookup! name;  package_rec.md5;               end
    def sha1 name;     package_rec = lookup! name;  package_rec.sha1;              end
    def datetime name; package_rec = lookup! name;  package_rec.datetime;          end


    def delete name
      cache_silo.delete(name) if cache_silo.exists?(name)
      DB::HistoryRecord.delete(silo_record, name)
    end

    def get name, &block
      retrieve_from_tape(name) unless cache_silo.exists?(name)
      cache_silo.get(name, &block)
    end

    def data_path name
      retrieve_from_tape(name) unless cache_silo.exists?(name)
      cache_silo.data_path name
    end

    def each
      DB::PackageRecord.list(silo_record, :extant => true).each { |rec| yield rec.name }
    end

    def fixity_report name = nil
      if name
        package_fixity_report name
      else
        silo_fixity_report
      end
    end

    private

    def slashify str
      str.gsub(%r{/+$}, '') + '/'
    end

    def lookup!  name
      rec = DB::PackageRecord.lookup(silo_record, name)
      raise "No such package #{name} on #{self}."            if rec.nil?
      raise "Package #{name} was deleted from #{self}."  unless rec.extant?
      rec
    end


    def get_tsm_info tsm
      open("/tmp/tsm.#{$$}.log", 'w') do |fh|
        info = []
        count = 0
        tsm.output do |line|
          count += 1
          info.push('TSM stdout: ' + line) if count < 40
          fh.puts 'TSM stdout: ' + line
        end
        count = 0
        tsm.errors do |line|
          count += 1
          info.push('TSM stderr: ' + line) if count < 40
          fh.puts 'TSM stdout: ' + line
        end
        info
      end
    end
    
    # def delete_from_tape name
    #   tsm = TsmExecutor.new(tivoli_server)
    #   tsm.delete slashify(File.join(self.filesystem, StoreUtils.hashpath(name)))
    #   if tsm.status > 8
    #     raise "TSM Execution Error - exit status #{tsm.status}; " + get_tsm_info(tsm).join("\n")
    #   end
    # end
    
    def retrieve_from_tape name
      cleanup_cache
      tsm = TsmExecutor.new(tivoli_server)
      
      destination = slashify(File.join(cache_silo.filesystem, StoreUtils.hashpath_parent(name)))
      source      = slashify(File.join(self.filesystem, StoreUtils.hashpath(name)))
      
puts "before tsm.restore(source=#{source}, destination=#{destination})"
      tsm.restore(source, destination)
puts "after tsm.restore(source=#{source}, destination=#{destination})"


      if tsm.status > 8
	raise "TSM Execution Error - exit status #{tsm.status}; " + get_tsm_info(tsm).join("\n")
      end

      if not cache_silo.exists?(name)
        raise "TSM Execution Error - Can't retrieve #{name} from #{self}; it hasn't been properly restored from tape to #{cache_silo}."
      end
    end
    
    def cleanup_cache
STDERR.puts "cleanupcache"
      cache_silo.each { |name| cache_silo.delete(name) if (DateTime.now - cache_silo.last_access(name)) > DAYS_TO_CACHE }
    end
  end # of class SiloTape
end # of module Store
