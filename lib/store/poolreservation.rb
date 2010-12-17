require 'store/utils'
require 'store/exceptions'
require 'store/silodb'
require 'store/db'

module Store

# Class PoolReservation provides a way to find and reserve a silo with
# enough free space to store a package of a known size.
#
# One proceeds as follows:
#
#   require 'store/db'
#   require 'store/poolreservation'
#   include Store
#
#   DB.setup('/etc/db.yml', 'store_master')
#   PoolReservation.lockfile_directory = '/var/run/silos/' # defaults to /var/tmp/
#
#   PoolReservation.new(size) do |silo|
#     silo.put(name) ...
#   end

  class PoolReservation

    @@lockfile_directory =  '/var/tmp/'

    MAX_RESERVATION = 3.0 / 24.0   # 3 hours expressed in days
    LOCK_TIMEOUT = 30              # seconds we'll wait to get at the DB ReservedDiskSpace table
    HEADROOM  = 256 * 1024         # we'll add a fudge factor of this many KB (about four times that taken up by the containing directories with metadata files).

    attr_reader :record_id

    def initialize size
      @record_id = nil      
      yield reservation_lock { best_fit_silo(size) }
    ensure
      rec = nil
      reservation_lock { rec.destroy if @record_id && (rec = DB::ReservedDiskSpaceRecord.get(@record_id)) }
    end

    def self.lockfile
      File.join(@@lockfile_directory, 'pool.lockfile')
    end

    def self.lockfile_directory= path
      me   =  Etc.getpwuid(Process.uid).name
      oops = "The directory used for writing a lockfile, '#{path}', "

      raise ConfigurationError, "#{oops} doesn't exist."              unless File.exists? path
      raise ConfigurationError, "#{oops} isn't actually a directory." unless File.directory? path
      raise ConfigurationError, "#{oops} isn't readable by #{me}."    unless File.readable? path
      raise ConfigurationError, "#{oops} isn't writable by #{me}."    unless File.writable? path

      @@lockfile_directory = path
    end

    private

    # writable_silos 
    # 
    # returns a list of candidate silos for a PUT, sorted by the name
    # of silo's filesystem. No checks are made for free space at this
    # time.

    def writable_silos
      list = []
      DB::SiloRecord.list.each do |rec|                       # TODO: part of the silo refactoring here.
        next unless rec.media_device == :disk
        silo = SiloDB.new rec.hostname, rec.filesystem
        list.push silo if silo.allowed_methods.include? :put
      end

      return list.sort { |a,b| a.filesystem <=> b.filesystem }
    end

    # reservation_lock
    #
    # provide a wrapper that ensures exclusive access to something.
    # In our case, that something is a set of certain write/delete
    # operations on the DB::ReservedDiskSpaceRecord table.  We use it
    # when we want to determine, augment, or delete disk space
    # reservations for a particular disk partition.

    def reservation_lock wait_time = LOCK_TIMEOUT
      open(PoolReservation.lockfile, 'w') do |fd| 
       Timeout.timeout(wait_time) { fd.flock(File::LOCK_EX) }
        yield
      end
    rescue Timeout::Error => e
      raise CouldNotLockPool, "Timed out waiting #{wait_time} seconds to get the pool lockfile #{PoolReservation.lockfile}: #{e.message}"
    end

    # best_fit_silo(size_needed) returns a silo, or raises a NoSilosAvailable exception.
    #
    # Our strategy is to sort silos by the size of their disk
    # partitions such that we get the partition with the least free
    # space that is greater than +size_needed+. We return one of the
    # silos that uses that partition. While it is true that at the FDA
    # a silo's filesystem maps to a unique partition, there's no
    # requirement in this code for that to be the case.  On succees,
    # we reserve +size_needed+ bytes for the selected paritition.

    def best_fit_silo size_needed

      available = {} ; reserved = {} ; silos = {}   # all hashes are keyed by partition

      DB::ReservedDiskSpaceRecord.partition_reservations(MAX_RESERVATION).each do |partition, reservation|
        reserved[partition] = reservation
      end

      writable_silos.each do |silo|

        partition = StoreUtils.disk_mount_point(silo.filesystem)
        freespace = StoreUtils.disk_free(partition) - (reserved[partition] || 0) - size_needed - HEADROOM

        next if freespace < 0

        available[partition] = freespace 

        silos[partition] ||= []
        silos[partition] << silo
      end

      raise NoSilosAvailable, "There are no free silos in this pool"  if available.empty?

      # find the partition with the least free space...
        
      partition = available.sort{ |a, b|  a[1] <=> b[1] }.map{ |rec|  rec[0] }.shift

      # ...and reserve +size_needed+ (and change) bytes for that partition.

      @record_id = DB::ReservedDiskSpaceRecord.create(:partition => partition, :size => size_needed + HEADROOM)['id']           
      return silos[partition].shift
    end
    
  end # of class 
end # of module Store
