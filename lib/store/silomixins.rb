require 'store/exceptions'


# TODO: don't need OpenStruct here, go to plain old struct


module Store
  module SiloMixinMethods

    # These utility methods (used by SiloDB and SiloTape) respond with
    # the allowed HTTP methods for a particular silo.  They include
    # both administrative limits as well as the inherent capabilities
    # of the different silos.  For instance, when the state of a
    # SiloDB is :disk_idling, no PUTs are allowed.
    #
    # Note, however, these are routines are meant for top-level (app)
    # requests.  We often need to use the class-based get/put/delete
    # methods for management tasks in spite of the externally allowed
    # settings.
    #
    # All of our instance variables will have a silo_record method,
    # which returns a DataMapper DB::SiloRecord object.

    # possible_methods
    #
    # An array of the symbols :get, :put, :delete, :post; all of the methods allowed
    # for the current state of this silo (e.g., tape masters do not allow :put)

    def possible_methods
      silo_record.possible_methods
    end

    # allowed_methods
    #
    # Returns a list from the set :get, :put, :delete, :post, of all
    # the methods currently allowed for this silo.  Those are all of
    # the possible_methods above, minus the additional admisitratively
    # forbidden methods.

    def allowed_methods
      silo_record.allowed_methods
    end

    def silo_directory? directory
      File.exists? directory and File.directory? directory and File.readable? directory and File.writable? directory
    end

    def allowed_states   # return alphabetically sorted, please

      case silo_record.state

      when :disk_master
        [ :disk_idling, :disk_master ]

      when :tape_master
        silo_directory?(silo_record.filesystem) ? [ :disk_idling, :tape_master ] : [ :tape_master ]

      when :disk_idling
        silo_directory?(silo_record.filesystem) ? [ :disk_idling, :disk_master, :tape_master ] : [ :disk_idling, :tape_master ]
      end
    end

    # handle retiring of silo;  we leave the data in place, but it won't be reused.

    def retired?
      silo_record.retired == true
    end

    def retire
      silo_record.retired = true
      silo_record.save or raise DataBaseError, "DB error: wasn't able to retire the silo #{silo_record.filesystem}."
    end

    def reactivate
      silo_record.retired = false
      silo_record.save or raise DataBaseError, "DB error: wasn't able to reactivate the silo #{silo_record.filesystem}."
    end



    # one of :disk_master, :disk_idling, :tape_master

    def state new_state = nil
      return silo_record.state if new_state.nil?
      return if new_state == silo_record.state


      case new_state
      when :disk_master
        raise StateChangeError, "Not allowed to change silo state to disk_master from tape_master." if silo_record.state == :tape_master
        raise StateChangeError, "Can't change silo state to disk_master since there's no filesystem for #{silo_record.filesystem}." unless silo_directory? silo_record.filesystem
      when :tape_master
        raise StateChangeError, "Not allowed to change silo state to tape_master from disk_master." if silo_record.state == :disk_master
      when :disk_idling
        raise StateChangeError, "Can't change silo state to disk_idling since there's no filesystem for #{silo_record.filesystem}." unless silo_directory? silo_record.filesystem
      else
        raise "Can't change silo state to unknown state #{new_state}."
      end

      # we need to clean out any forbidden states on state change, or they'll be confusingly reapply on the
      # next state change.

      silo_record.forbidden = []
      silo_record.state = new_state
      silo_record.save or raise DataBaseError, "DB error: wasn't able to change state to #{new_state} for silo #{silo_record.filesystem}."
      new_state
    end


    def idle
      state :disk_idle
    end

    def media
      silo_record.media_device
    end

    def allow method
      silo_record.allow method
    end

    def forbid method
      silo_record.forbid method
    end

    def get_ok?
      silo_record.allowed_methods.include? :get
    end

    def delete_ok?
      silo_record.allowed_methods.include? :delete
    end

    def put_ok?
      silo_record.allowed_methods.include? :put
    end

    def post_ok?
      silo_record.allowed_methods.include? :post
    end

    # Because all our silos are under one root, we can use the
    # last part of the filesystem as the name of the silo.

    def name
      filesystem.split(File::SEPARATOR).pop
    end

  end  # of module SiloMixinMethods



  module Fixity

    # Designed for mixing into SiloDB and SiloTape; instance variables
    # include silo_record (Store::DB::SiloRecord, a datamapper
    # object), with filesystem and hostname methods available.

    # For all the existing packages on this silo, get the times of the
    # current fixity checks, and return the date of earliest of them.

    def oldest_fixity
      DB::PackageRecord.min(:latest_timestamp, :extant => true, :silo_record => silo_record)
    end

    def newest_fixity
      DB::PackageRecord.max(:latest_timestamp, :extant => true, :silo_record => silo_record)
    end

    ### TODO: these need to be pulled out into different more appropriately named mixin, or just back into DB, maybe:

    def package_count search = nil
      if search
        DB::PackageRecord.count(:extant => true, :silo_record => silo_record, :name.like => "%#{search}%")
      else
        DB::PackageRecord.count(:extant => true, :silo_record => silo_record)
      end
    end

    ### TODO: see above - these three don't really belong here either:

    def package_names
      DB::PackageRecord.list(silo_record).map{ |rec| rec.name }
    end

    def package_names_by_page page, number_per_page, search = nil
      if search
        names = DB::PackageRecord.list(silo_record,
                                       :order     => [ :initial_timestamp.desc ],
                                       :name.like => "%#{search}%",
                                       :extant    => true,
                                       :limit     => number_per_page,
                                       :offset    => number_per_page * (page - 1))
      else
        names = DB::PackageRecord.list(silo_record,
                                       :order     => [ :initial_timestamp.desc ],
                                       :extant => true,
                                       :limit  => number_per_page,
                                       :offset => number_per_page * (page - 1))
      end
      names.map{ |rec| rec.name }
    end


    def package_fixity_report name

      ### TODO: we'd like to extend history records to include sizes, and change package records
      ### to have initial_size and latest_size.  Step one of the refactoring is to use the 'size'
      ### record from the host

      return unless pkg = DB::PackageRecord.lookup(silo_record, name)

      fixity_records  = []
      deleted_on      = nil
      created_on      = nil
      count           = 0
      max_time        = DateTime.strptime('1970-01-01', '%Y-%m-%d')
      min_time        = DateTime.now
      history_records = DB::HistoryRecord.list(silo_record, name)  ### TODO: list raw here, perhaps, for speedup


      # Iterate through all of the history records for a package -
      # when we encounter a delete, truncate the list and start over
      # (this handles a case where we've deleted a package by name and
      # resubmitted it - not really done in the new incarnation of
      # daitss, but we need backwards support).

      history_records.each do |rec|
        case
        when rec.action == :put then
          fixity_records = []
          count = 1
          fixity_records.push({ :action => rec.action,
                                :md5    => rec.md5,
                                :sha1   => rec.sha1,
                                :size   => pkg.size,
                                :time   => rec.timestamp })

        when (rec.action == :fixity and rec.sha1.nil? and rec.md5.nil?) then
          count += 1
          fixity_records.push({ :action => rec.action,
                                :md5    => "",
                                :sha1   => "",
                                :time   => rec.timestamp,
                                :size   => 0,
                                :status => :mising })

        when rec.action == :fixity then
          count += 1
          fixity_records.push({ :action => rec.action,
                                :md5    => rec.md5,
                                :sha1   => rec.sha1,
                                :time   => rec.timestamp,
                                :size   => pkg.size,
                                :status => (rec.md5 == pkg.initial_md5 and rec.sha1 == pkg.initial_sha1) ? :ok : :fail })

        when rec.action == :delete then
          count = 0
          fixity_records = []   # start over
        end

        max_time = rec.timestamp > max_time ? rec.timestamp : max_time
        min_time = rec.timestamp < min_time ? rec.timestamp : min_time
      end

      OpenStruct.new(:filesystem         => filesystem,
                     :hostname           => hostname,
                     :package            => name,
                     :fixity_records     => fixity_records,
                     :fixity_check_count => count,
                     :first_fixity_check => min_time,
                     :last_fixity_check  => max_time,
                     :created            => created_on,
                     :deleted            => deleted_on)
    end


    # Here's the sort of serializations that fixity needs to support (XML here, but JSON and CSV possible):
    #
    # <SILOCHECK silo="/daitssfs/016" host="fclnx31.fcla.edu" fixity_check_count="4507" first_fixity_check="2010-02-24T11:21:52-05:00" last_fixity_check="2010-03-24T10:02:25-04:00">
    #   <FIXITY name="E20090617_AAABSY" sha1="20638e5c667193b8cf42b5da4ad9e98e89ca3466" md5="689b007da0d135210dab6abda1b62edd" time="2010-02-24T12:25:21-05:00" status="ok"/>
    #   <FIXITY name="E20090617_AAABTA" sha1="bc758033d20981c7310b1574d97b07b02b5aa910" md5="86ae8ae50fce2fc9d5cd00d29efb4f41" time="2010-02-24T11:52:41-05:00" status="ok"/>
    #     ....
    # </SILOCHECK>

    def silo_fixity_report
      fixity_records = []
      count          = 0
      max_time       = DateTime.parse('1970-01-01', "%Y-%m-%d")
      min_time       = DateTime.now

      DB::PackageRecord.raw_list(silo_record, :extant => true).each do |rec|
        fix = {
          :name   => rec.name,
          :md5    => rec.latest_md5,
          :sha1   => rec.latest_sha1,
          :size   => rec.size,
          :time   => rec.latest_timestamp
        }

        case
        when (rec.latest_md5.nil? and rec.latest_sha1.nil?) then 
            fix[:status] = :missing
            fix[:sha1]   = ''
            fix[:md5]    = ''
            fix[:size]   = 0
        when (rec.latest_md5 == rec.initial_md5 and rec.latest_sha1 == rec.initial_sha1) then
            fix[:status] = :ok
        else
          fix[:status] = :fail
        end

        fixity_records.push(fix)

        max_time = rec.latest_timestamp > max_time ? rec.latest_timestamp : max_time
        min_time = rec.latest_timestamp < min_time ? rec.latest_timestamp : min_time
        count   += 1
      end

      OpenStruct.new(:filesystem         => filesystem,
                     :hostname           => hostname,
                     :fixity_records     => fixity_records,
                     :fixity_check_count => count,
                     :first_fixity_check => min_time,
                     :last_fixity_check  => max_time)

    end
  end # of module Fixity
end # of module Store
