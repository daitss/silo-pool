require 'store/utils'
require 'store/exceptions'
require 'store/silodb'
require 'store/db'

module Store

# Class Pool
# Utility functions to get presentation
#
# One proceeds as follows:
#
#   require 'store/db'
#   require 'store/pool'
#
#   include Store
#
#   DB.setup('/etc/db.yml', 'store_master')
#   Pool.fixities do |rec|
#

#
#   PoolReservation.new(size) do |silo|
#     silo.put(name) ...
#   end

  class Pool

    def self.fixity_report

      fixity_records = []
      count          = Store::DB::PackageRecord.count(:extant => true )
      max_time       = DateTime.parse('1970-01-01')
      min_time       = DateTime.now

      Store::DB::PackageRecord.all( :order => [ :name.asc ], :extant => true ).each do |rec|
        fixity_records.push({ :name   => rec.name, 
                              :status => (rec.latest_md5 == rec.initial_md5 and rec.latest_sha1 == rec.initial_sha1) ? :ok : :fail,
                              :md5    => rec.latest_md5, 
                              :sha1   => rec.latest_sha1, 
                              :time   => rec.latest_timestamp })

        max_time = rec.latest_timestamp > max_time ? rec.latest_timestamp : max_time
        min_time = rec.latest_timestamp < min_time ? rec.latest_timestamp : min_time
        count   += 1
      end

      OpenStruct.new(# :hostname           => hostname, 
                     :fixity_records     => fixity_records, 
                     :fixity_check_count => count,
                     :first_fixity_check => min_time, 
                     :last_fixity_check  => max_time)
    end
  end        
end
