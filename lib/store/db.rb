require 'dm-core'
require 'dm-constraints'
require 'dm-types'
require 'dm-validations'
require 'dm-aggregates'
require 'dm-transactions'
require 'dm-migrations'
require 'enumerator'
require 'socket'
require 'store/exceptions'
require 'time'
require 'store/utils'       

# TODO: add code to ensure that the last compoent of the silo filesystem is unique; it's an assumption
# but not explicitly enfoced.


# Used by SiloDB, SiloTapeDB classes; Used by utility programs such as fixity.

module Store
  module DB

    # The setup routine can take either one string or two; the
    # deprecated two-argument version handles a legacy method of
    # initializing from a yaml and a key into the hash produced from
    # that yaml file.

    # We are especially careful with the setup since this is where
    # operations staff could get confused about what is required. This
    # is problematic since very little reporting machinery can be set
    # up at the time setup is called (e.g., no logging).
    
    def self.setup *args

      connection_string = (args.length == 2 ? StoreUtils.connection_string(args[0], args[1]) : args[0])
      dm = DataMapper.setup(:store_master, connection_string)

      begin
        dm = DM.setup connection_string        
        dm.select('select 1 + 1')  # if we're going to fail (with, say, a non-existant database), let's fail now.
        dm
      rescue => e
        raise ConfigurationError, "Failure setting up the silo-pool database: #{e.message}"
      end
    end


    class DM
      def self.setup db
        dm = DataMapper.setup(:default, db)
        DataMapper.finalize
        dm
      end

      def self.automigrate!
        SiloRecord.auto_migrate!
        PackageRecord.auto_migrate!
        HistoryRecord.auto_migrate!

        ReservedDiskSpace.auto_migrate!
        Authentication.auto_migrate!

        self.patch_tables
      end

      def self.autoupgrade!
        SiloRecord.auto_upgrade!
        PackageRecord.auto_upgrade!
        HistoryRecord.auto_upgrade!
        ReservedDiskSpace.auto_upgrade!
        Authentication.auto_upgrade!
      end


      def self.patch_tables
        db = repository(:default).adapter
        postgres_commands = [ 
                             'alter table histories alter timestamp type timestamp with time zone',
                             'alter table packages alter initial_timestamp type timestamp with time zone',
                             'alter table packages alter latest_timestamp type timestamp with time zone',
                             'alter table reserved_disk_spaces alter timestamp type timestamp with time zone',
                             'create index index_packages_initial_timestamp_silo_record_extant on packages(initial_timestamp, silo_record_id, extant)',
                             'create index index_packages_latest_timestamp_silo_record_extant on packages(latest_timestamp, silo_record_id, extant)'
                            ]

        if db.methods.include? 'postgres_version'
          postgres_commands.each { |sql| db.execute sql }
        end
      end

    end # of class DM


    # Way overkill for what we use it for: table with at most one row, for user name 'admin'.

    class Authentication

      include DataMapper::Resource
      storage_names[:default] = 'authentications'
      
      property :id,              Serial
      property :name,            String, :required => true
      property :salt,            String, :required => true
      property :password_hash,   String, :required => true


      def self.lookup username
        first(:name =>username)
      end

      def self.create username, password
        rec = Authentication.first(:name => username) || Authentication.new(:name => username)
        
        rec.password = password
        raise "Can't create new credentials for #{administrator}: #{rec.errors.full_messages.join('; ')}." unless rec.save
        rec
      end

      def password= password
        raise BadPassword, "No password supplied" unless password and password.length > 0

        self.salt = rand(1_000_000_000_000_000_000).to_s(36)
        self.password_hash = Digest::MD5.hexdigest(salt + password)
        raise "Can't create new password for #{self.name}: #{self.errors.full_messages.join('; ')}." unless self.save
      end

      def authenticate password
        Digest::MD5.hexdigest(self.salt + password) == self.password_hash
      end

      def self.clear
        Authentication.destroy
      end

    end


    class SiloRecord

      def self.states
        [ :disk_master, :disk_idling, :disk_copied, :tape_master ]   # to do deprecate :disk_copied (db alter?)
      end


      def self.methods
        [ :get, :put, :delete, :post, :options ]
      end

      include DataMapper::Resource
      storage_names[:default] = 'silos'

      property  :id,          Serial
      property  :filesystem,  String, :length => 255, :required => true
      property  :hostname,    String, :length => 127, :required => true
      property  :state,       Enum[ *states  ], :default =>   :disk_master
      property  :forbidden,   Flag[ *methods ], :default => [ :delete, :put, :post, :options ]  # :post seems to be a no-op?
      property  :retired,     Boolean, :default  => false

      has n,    :package_record, :constraint => :destroy

      validates_uniqueness_of :filesystem, :scope => :hostname

      def to_s
        "#<SiloRecord: #{self.hostname}:#{self.filesystem}>"
      end

      def self.create hostname, filesystem
        filesystem = File.expand_path(filesystem)
        silo_rec = SiloRecord.new
        silo_rec.attributes = { :filesystem => filesystem, :hostname => hostname.downcase  }
        raise "Can't create a new silo record for #{hostname}:#{filesystem}: #{silo_rec.errors.full_messages.join('; ')}." unless silo_rec.save
        silo_rec
      end

      def self.lookup hostname, filesystem
        filesystem = File.expand_path(filesystem)  # strips trailing slash..
        SiloRecord.first( :filesystem => filesystem, :hostname => hostname.downcase )
      end

      # The web service names silos using abbreviated verision of the
      # silo's filesystem - the last path component of the silo
      # filesystem (so the last filesystem component has to be unique
      # across all filesystem).

      def self.lookup_by_partition hostname, partition
        SiloRecord.first( :filesystem.like => '%' + partition, :hostname => hostname.downcase )
      end

      # list all of the silos known to us, restricted to a particular hostname if needed.

      def self.list hostname = nil
        options = { :order => [ :hostname.asc, :filesystem.asc ] }
        options[:hostname] = hostname.downcase if hostname
        SiloRecord.all(options)
      end      


      # record a missing package; name had better exist as a package in the PackageRecord table

      def missing name
        HistoryRecord.missing self, name
      end


      def short_name
        filesystem.split('/').pop
      end

      def media_device
        case state
        when :disk_master, :disk_idling, :disk_copied
          :disk
        when :tape_master
          :tape
        else
          raise "Disk in an unhandled state: #{state}"
        end
      end

      def make_tape_master
        self.state = :tape_master
        self.save!
      end

      def possible_methods
        case 
        when retired == true
          [ :get ]
        when state == :disk_master           # Now a disk-based silo can do any of these: GET, PUT, DELETE
          [ :delete, :get, :put ]
        when state == :disk_idling           # While here we're in the process of copying to tape; no changes permitted (GETs OK)
          [ :get ]
        when state == :tape_master           # When entirely using tape we only allow individual GETs and DELETEs.
          [ :delete, :get ]
        else
          Raise "Unhandled condition for determining possible methods for silo #{self.hostname}:#{self.filesystem}."
        end
      end

      def allowed_methods
        possible_methods - forbidden
      end

      def allow *methods
        methods.each do |method|
          method = method.class == String ? method.downcase.to_sym : method
          if not possible_methods.include? method
            raise ConfigurationError, "Can't allow HTTP method #{method.to_s.upcase} for silo #{self.hostname}:#{self.filesystem}: silo is in the #{self.state.to_s.upcase.gsub('_', ' ')} state, which precludes that setting."
          end
          self.forbidden -= [ method ]
        end
        self.save!
      end

      def forbid *methods
        methods.each do |method|
          method = method.class == String ? method.downcase.to_sym : method
          if not SiloRecord.methods.include? method
            raise ConfigurationError, "Can't allow HTTP method #{method.to_s.upcase} for silo #{self.hostname}:#{self.filesystem}: it is an unsupported method."
          end
          self.forbidden += [ method ] unless self.forbidden.include? method
        end
        self.save!
      end

    end # of class SiloRecord


    # PackageRecord keeps track of the current state of a package, so
    # we can get the most recent PUT, DELETE, and FIXITY events for a
    # package.  The complete list of records are kept in the
    # HistoryRecord table. HistoryRecord is extensive and slow to access.
    #
    # In point of fact, PackageRecords are normally populated by
    # side-effect, as when a HistoryRecord is updated or when
    # missing packages are discovered, which happens wheng
    # SiloRecord.missing(PackageName) is called.
    #
    # PUTs are recorded using the :initial_timestamp, :initial_sha1,
    # and :initial_md5 columns.
    #
    # DELETEs are indicated by the :extant column being set to false.
    # (no date information is relevant - see the histories table for
    # that. This is because, generally speaking, only lists of
    # extant packages are used) NOTE: :extant is NEVER used to
    # indicate a missing package.
    #
    # FIXITYs are recorded using the :latest_* columns.  There is an
    # important special case of a fixity event: the package has gone
    # missing. In that case, the latest_sha1 and latest_md5 fields are
    # null.
    

    class PackageRecord
      include DataMapper::Resource
      storage_names[:default] = 'packages'

      property   :id,                 Serial
      property   :extant,             Boolean,  :default  => true, :index => true
      property   :name,               String,   :required => true, :index => true

      property   :initial_sha1,       String,   :required => true, :length => (40..40), :index => true  # data from last PUT
      property   :initial_md5,        String,   :required => true, :length => (32..32), :index => true
      property   :initial_timestamp,  DateTime, :required => true, :index => true                       # package last_modified time

      property   :size,               Integer,  :required => true, :index => true, :min => 0, :max => 2**63 - 1
      property   :type,               String,   :required => true

      # if missing, the following checksums will be null:

      property   :latest_sha1,        String,   :length => (40..40), :index => true        # latest FIXITY
      property   :latest_md5,         String,   :length => (32..32), :index => true
      property   :latest_timestamp,   DateTime, :index => true                             # and its time

      belongs_to :silo_record
      has n,     :history_record,     :constraint => :destroy

      validates_uniqueness_of  :name, :scope => :silo_record_id   ### TODO: make sure I have a test that covers this....

      def to_s
        "#<PackageRecord: #{self.name} for #{silo_record.hostname} at #{silo_record.filesystem}>"
      end

      def md5
        initial_md5
      end

      def sha1
        initial_sha1
      end

      def datetime
        initial_timestamp
      end

      def missing?
        latest_sha1.nil? and latest_md5.nil?
      end

      def url port = 80, scheme = 'http'
        port_str = port.to_i == 80 ? '' : ":#{port}"
        scheme + '://' + silo_record.hostname + port_str + '/' + silo_record.filesystem.split('/').pop + '/data/' + name
      end


      # PackageRecord.create always is performed by HistoryRecord.put
      # when a PUT has been perfomed to this silo.

      # OPTIONS is a hash that contains: Strings :md5, :sha1 and
      # :type; DateTime :timestamp; and the Integer :size.  The
      # intial_<field> and latest_<field> in a package record are
      # initially the same values for fields _md5, _sha1, and
      # _timetamp; silo PUT code computes these from the saved data to
      # make sure the :md5 and :size values match the data gathered
      # from the HTTP headers.
    

      def self.create silo_record, name, options
        package_record = PackageRecord.new

        attributes = Hash.new

        attributes[:initial_md5]       = options[:md5]
        attributes[:initial_sha1]      = options[:sha1]
        attributes[:initial_timestamp] = options[:timestamp]

        attributes[:latest_md5]        = options[:md5]
        attributes[:latest_sha1]       = options[:sha1]
        attributes[:latest_timestamp]  = options[:timestamp]

        attributes[:size]              = options[:size]
        attributes[:type]              = options[:type]

        attributes[:silo_record]       = silo_record
        attributes[:name]              = name

        package_record.attributes = attributes

        if not package_record.save
          raise "Can't create a new package #{name} for silo #{silo_record} - #{package_record.errors.full_messages.join('; ')}." 
        end

        package_record
      end

      def self.lookup silo_record, name
        PackageRecord.first( :silo_record => silo_record,  :name => name )
      end

      # List all of the package records for this silo; by default order by name.
      # DataMapper options may be specified by hash notation, which override the
      # defaults.

      def self.list silo_record, options = {}
        params = { :order => [ :name.asc ] }
        params.merge! options
        params[:silo_record]  = silo_record   # we don't let this get over-ridden.
        PackageRecord.all(params)
      end

      # This allows us to go a bit faster than the above

      def self.raw_list silo_record = nil, options = {}
        clauses = []
        options.each do |k, v| 
          if [ FalseClass, TrueClass, Fixnum ].include? v.class
            clauses.push  "#{k.to_s} = #{v}"
          else
            clauses.push  "#{k.to_s} = '#{v}'"
          end
        end
        clauses.push "silo_record_id = #{silo_record['id']}" if silo_record

        sql  =    "SELECT id, name, extant, size, type, initial_sha1, initial_md5, initial_timestamp, latest_sha1, latest_md5, latest_timestamp "
        sql +=      "FROM packages "
        sql +=     "WHERE #{clauses.join(' AND ')} " unless clauses.empty?
        sql +=  "ORDER BY name"

        list = repository(repository).adapter.select(sql)        
      end


      # A late addtion, get the entire list of active fixities at a point in time in an efficient manner.

      def self.list_all_fixities url, options = {}
        clauses = []

        if options[:stored_before]
          clauses.push "packages.initial_timestamp < '#{options[:stored_before]}'"
        end

        # We have to do some conversions to get datamapper from using
        # the very expensive datetime constructor. So we let postgres
        # do the heaving lifting (since we can't use mysql or oracle
        # anyway, due to the constraint of requiring the use of 'time
        # with timezone' in postgres...).  Specifically, we get
        # postgres to turn the 'time with timezone' into a string
        # representing the UTC time. This keeps datamapper from
        # coercing it to a datetime object.  This provides an order of
        # magnitude speedup (e.g. producing the current list of
        # 304,000 records goes from 20 minutes to 2).

        sql  =  
          "SELECT packages.name, " +

          "(CASE WHEN packages.latest_sha1 IS NULL THEN '' " +
                "ELSE packages.latest_sha1 " +
           "END) " +
          "AS sha1, " +

          "(CASE WHEN packages.latest_md5  IS NULL THEN '' " +
                "ELSE packages.latest_md5 " +
          "END) " +
          "AS md5, " +

          "(CASE WHEN packages.latest_sha1 IS NULL AND packages.latest_md5 IS NULL THEN 0 " +
                "ELSE packages.size " +
          "END) " +
          "AS size, " +

          "REPLACE(TO_CHAR(packages.initial_timestamp AT TIME ZONE 'GMT', 'YYYY-MM-DD HH24:MI:SSZ'), ' ', 'T') " +
          "AS put_time, " +

          "REPLACE(TO_CHAR(packages.latest_timestamp  AT TIME ZONE 'GMT', 'YYYY-MM-DD HH24:MI:SSZ'), ' ', 'T') " +
          "AS fixity_time, " +

          "(CASE WHEN packages.latest_sha1 IS NULL AND packages.latest_md5 IS NULL THEN 'missing' " +
                "WHEN packages.latest_sha1 = packages.initial_sha1 AND packages.latest_md5 = packages.initial_md5 THEN 'ok' " +
                "ELSE 'fail' " +
          "END) " +
          "AS status, " +

          "'#{url}' || SUBSTRING(silos.filesystem FROM '[^/]*$') || '/data/' || packages.name " +
          "AS location " +

          "FROM packages, silos WHERE packages.silo_record_id = silos.id " +
                                 "AND NOT silos.retired " +
                                 "AND silos.hostname = '#{url.host}' " +
                                 "AND packages.extant " +

          ( clauses.empty?  ? "" : 'AND ' +  clauses.join(' AND ') + ' ') +

          "ORDER BY packages.name"

        return repository(repository).adapter.select(sql)
      end


    end # of class PackageRecord


    ### TODO: we want to populate a size field as well, need to add a size here, and 
    ### perhaps a latest_size on package record.  For now, we're just using the size info
    ### from package to ensure we're getting the functional interface correct - see the silo
    ### mixins.

    class HistoryRecord

      def self.actions
        [ :put, :fixity, :delete ]    # implicity ordering historical workflow here.
      end

      include DataMapper::Resource

      storage_names[:default] = 'histories'

      property   :id,        Serial,  :required => true, :index => true, :min => 0, :max => 2**63 - 1
      property   :action,    Enum[ *actions ], :required => true
      property   :sha1,      String,           :required => false, :length => (40..40)
      property   :md5,       String,           :required => false, :length => (32..32)
      property   :timestamp, DateTime,         :default  => lambda { |resource, property| DateTime.now }
      belongs_to :package_record

      # called with either a (package_record) or (silo_record, package_name) as arguments

      def self.list *args
        package_record = (args.length == 1) ?  args[0] : PackageRecord.lookup(*args)
        HistoryRecord.all(:package_record => package_record, :order => [ :timestamp.asc ])
      end

      # HistoryRecord.put(package_record, hash) or  HistoryRecord(silo_record, package_name, hash)
      #
      # hash must have the following attributes:
      #
      #  * md5
      #  * sha1
      #  * timestamp
      #  * size
      #  * type

      def self.put *args  # (package_record, attributes) or (silo_record, package_name, attributes)

        hashargs       = args.pop

        [ :md5, :sha1, :timestamp, :size, :type ].each do |key|
          raise "Problem creating historical PUT record: missing #{key.to_s} data" unless hashargs.include? key
        end

        package_record = args.length == 1 ? args[0] : PackageRecord.lookup(args[0], args[1])

        md5  = hashargs[:md5]
        sha1 = hashargs[:sha1]
        time = hashargs[:timestamp]

        PackageRecord.transaction do

          yield if block_given?

          if not package_record
            package_record = PackageRecord.create(args[0], args[1], hashargs)
          end


          history_record = HistoryRecord.new
          history_record.attributes = { :package_record => package_record,
                                        :action         => :put, 
                                        :md5            => md5, 
                                        :sha1           => sha1, 
                                        :timestamp      => time }

          if not history_record.save
            raise "HistoryRecord - put - can't create a new PUT record for package #{package_record} - #{history_record.errors.full_messages.join('; ')}." 
          end

          package_record.attributes = { :initial_sha1 => sha1, 
                                        :latest_sha1  => sha1,

                                        :initial_md5 => md5,
                                        :latest_md5  => md5,

                                        :initial_timestamp  => time,
                                        :latest_timestamp   => time,

                                        :extant => true }
          if not package_record.save
            raise "HistoryRecord - put - can't create current md5 and sha1 records in PUT for package #{package_record} - #{package_record.errors.full_messages.join('; ')}." 
          end

          history_record
        end
      end

      def self.fixity *args  # (package_record, hashes) or (silo_record, package_name, hashes)
        hashes = args.pop
        hashes[:timestamp] = DateTime.now unless hashes.include? :timestamp
        HistoryRecord.transaction do
          package_record = (args.length == 1) ?  args[0] : PackageRecord.lookup(*args)
          raise "HistoryRecord - fixity - can't look up the package based on arguments (#{args.join(', ')})." unless package_record.class == PackageRecord
          history_record = HistoryRecord.new
          history_record.attributes = {:package_record => package_record, :action => :fixity, :md5 => hashes[:md5], :sha1 => hashes[:sha1], :timestamp => hashes[:timestamp]}
          raise "HistoryRecord - fixity - can't create a new FIXITY record for package #{package_record} - #{history_record.errors.full_messages.join('; ')}." unless history_record.save
          package_record.attributes = {:latest_sha1 => hashes[:sha1],  :latest_md5 => hashes[:md5],  :latest_timestamp => hashes[:timestamp]}
          raise "HistoryRecord - fixity - can't update current md5 and sha1 records in FIXITY record for package #{package_record} - #{package_record.errors.full_messages.join('; ')}." unless package_record.save
          history_record
        end
      end

      def self.delete *args  # (package_record) or (silo_record, package_name)
        HistoryRecord.transaction do
          package_record = (args.length == 1) ?  args[0] : PackageRecord.lookup(*args)
          raise "HistoryRecord - delete - can't look up the package based on arguments (#{args.join(', ')})." unless package_record.class == PackageRecord
          history_record = HistoryRecord.new
          now = Time.now
          history_record.attributes = {:package_record => package_record, :action => :delete }
          raise "HistoryRecord - delete - can't create a new DELETE record for package #{package_record} - #{history_record.errors.full_messages.join('; ')}." unless history_record.save
          package_record.attributes = {:extant => false}
          raise "HistoryRecord - delete - can't update the existence field for package #{package_record} - #{package_record.errors.full_messages.join('; ')}." unless package_record.save
          history_record
        end
      end

      # just like self.fixity, but with null md5 and sha1 values

      def self.missing *args  # (package_record) or (silo_record, package_name)
        HistoryRecord.transaction do
          package_record = (args.length == 1) ?  args[0] : PackageRecord.lookup(*args)

          raise "HistoryRecord - missing - can't look up the package based on arguments (#{args.join(', ')})." unless package_record.class == PackageRecord
          history_record = HistoryRecord.new
          now = Time.now
          history_record.attributes = { :package_record => package_record, :action => :fixity, :md5 => nil, :sha1 => nil, :timestamp => now }

          raise "HistoryRecord - missing - can't create a new MISSING record for package #{package_record} - #{history_record.errors.full_messages.join('; ')}." unless history_record.save
          package_record.attributes = {:latest_sha1 => nil, :latest_md5 => nil, :latest_timestamp => now }
          raise "HistoryRecord - missing - can't update the existence field for package #{package_record} - #{package_record.errors.full_messages.join('; ')}." unless package_record.save
          history_record
        end
      end


    end # of class HistoryRecord

    
    class ReservedDiskSpace 

      include DataMapper::Resource
      storage_names[:default] = 'reserved_disk_spaces'

      property  :id,          Serial
      property  :partition,   String,   :required => true, :index => true, :length => 255
      property  :timestamp,   DateTime, :required => true, :index => true, :default  => lambda { |resource, property| DateTime.now }
      property  :size,        Integer,  :required => true, :index => true, :min => 0, :max => 2**63 - 1      

      # remove all records from the database older than +max_reservation+.
      # +max_reservation+ is expressed in days.

      def self.cleanout_stale_reservations max_reservation
        ReservedDiskSpace.all(:timestamp.lt => DateTime.now - max_reservation).destroy
      end
      
      def self.distinct_partitions
        ReservedDiskSpace.all.map{ |rec| rec.partition }.uniq.sort
      end
        
      # return hash of partitions and sizes: { partition_name => space, ... }
      # it automatically removes records older than max_reservation days.

      def self.partition_reservations(max_reservation)
        ReservedDiskSpace.cleanout_stale_reservations(max_reservation)
        reservations = {}
        
        ReservedDiskSpace.distinct_partitions.each do |partition|
          reservations[partition] = ReservedDiskSpace.sum(:size, :partition => partition)
        end
        reservations
      end

    end # of class ReservedDiskSpace
  end # of module DB
end # of module Store
