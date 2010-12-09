require 'store/utils'
require 'store/exceptions'
require 'store/silodb'
require 'store/db'

module Store


# Class PoolReservation provides a way to find and reserve a silo with enough free space
# store a package of a known size.
#
# One proceeds as follows:
#
#   reservation = PoolReservation.new(size)
#   reservation.silo.put(name) ... # put your SIZE bytes of data
#   reservation.release    


  class PoolReservation


    MAX_HOLD_RESERVATION = 3.0 / 24.0    # 3 hours in day units


    attr_reader :size, :record_id, :silo

    def initialize size
      @size = size
      @record_id = nil
      @silo = best_fit(size)
    end
    
    def release
      # remove the record.  If we don't find it, we don't really worry - it will stale out eventually.
    end

    # available_silos 

    def available_silos
      list = []
      DB::SiloRecord.list.each do |rec|
        # is it a disk based silo?
        # does it support PUTs currently?
        # instantiate it, add to list
      end
      return list
    end

    def best_fit size_needed

      silo_partitions = {} 
      freespace       = {}

      available_silos.each do |silo| 
        partition = StoreUtils.disk_mount_point(silo.filesystem)
        silo_partitions[partition] ||= []
        silo_partitions[partition] << silo
        freespace[partition]  = StoreUtils.disk_free(partition)
      end


      DB::ReservedDiskSpaceRecord.transaction do

        DB::ReservedDiskSpaceRecord.list.each do |rec|
          if  (DateTime.now - rec.timestamp) > MAX_HOLD_RESERVATION
            rec.delete
          else
            freespace[rec.partition] -= rec.reserved_space unless freespace[rec.partition].nil?
          end
        end
        
        # sort partitions by least amnount of free space
        # select the first one that's large enough to hold size_needed        
        # create a reservation entry for the partition.
      end
      
      # From the list of silos, find the first one that uses this partition, returning
      # it

    rescue => e
      # Handle transaction error with timeout and retry; 500 error if we have to give up
    else
      # Raise 4xx class error if there are no silos large enough; return silo
    end



    

    
  end # of class SiloReservation
end # of module Store
