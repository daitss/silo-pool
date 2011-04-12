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

# TODO:  make sure last compoent of the silo filesystem is unique


# Used by SiloDB, SiloTapeDB classes; Used by utility programs such as fixity.

module Store
  module DB

    # We are especially careful with the setup since this is where
    # operations staff could get confused about what is required,
    # especially since very little reporting machinery can be set up
    # at the time it is called.

    def self.setup yaml_file, key
      oops = "DB setup can't"

      raise ConfigurationError, "#{oops} understand the configuration file name - it's not a filename string, it's a #{yaml_file.class}."  unless (yaml_file.class == String)
      raise ConfigurationError, "#{oops} understand key for the configuration file #{yaml_file} - it's not a string, it's a #{key.class}." unless (key.class == String)
      begin
        dict = YAML::load(File.open(yaml_file))
      rescue => e
        raise ConfigurationError, "#{oops} parse the configuration file #{yaml_file}: #{e.message}."
      end
      raise ConfigurationError, "#{oops} parse the data in the configuration file #{yaml_file}." if dict.class != Hash
      dbinfo = dict[key]
      raise ConfigurationError, "#{oops} get any data from the #{yaml_file} configuration file using the key #{key}."                                    unless dbinfo
      raise ConfigurationError, "#{oops} get the vendor name (e.g. 'mysql' or 'postsql') from the #{yaml_file} configuration file using the key #{key}." unless dbinfo.include? 'vendor'
      raise ConfigurationError, "#{oops} get the database name from the #{yaml_file} configuration file using the key #{key}."                           unless dbinfo.include? 'database'
      raise ConfigurationError, "#{oops} get the host name from the #{yaml_file} configuration file using the key #{key}."                               unless dbinfo.include? 'hostname'
      raise ConfigurationError, "#{oops} get the user name from the #{yaml_file} configuration file using the key #{key}."                               unless dbinfo.include? 'username'

      # Example string: 'postgres://root:topsecret@localhost:5432/silos'

      connection_string = dbinfo['vendor'] + '://' +
                          dbinfo['username'] +
                         (dbinfo['password'] ? ':' + dbinfo['password'] : '') + '@' +
                          dbinfo['hostname'] +
                         (dbinfo['port'] ? ':' + dbinfo['port'].to_s : '') + '/' +
                          dbinfo['database']
      begin
        dm = DM.setup connection_string        
        dm.select('select 1 + 1')  # if we're going to fail (with, say, a non-existant database), let's fail now - thanks Franco for the SQL idea.
        dm
      rescue => e
        raise ConfigurationError,
              "Failure setting up the #{dbinfo['vendor']} #{dbinfo['database']} database for #{dbinfo['username']} on #{dbinfo['hostname']} (#{dbinfo['password'] ? 'password supplied' : 'no password'}) - used the configuration file #{yaml_file}: #{e.message}"
      end
    end

    # A utility to handle a variety of argument signatures.
    #
    # foo(package_record)
    # foo(package_record, :this => 0, :that => 2)
    # foo(silo_record, package_name)
    # foo(silo_record, package_name, :this => 0, :that => 2)
    #
    # This will do that parsing, returning a package_record (or nil if not found) and a hash

    # def self.destructured_package_lookup *original_args
    #   args = original_args.clone
    #   pkg = nil

    #   if args[0].class == PackageRecord
    #     pkg = args.shift
    #   elsif args[0].class == SiloRecord and args[1] == String
    #     pkg = PackageRecord.lookup(args.shift, args.shift)
    #   else
    #     raise "Argument error: expected (silo_record, package_name_string) or (package_record)"
    #   end

    #   raise "Argument error: odd number of options" unless arguments.length % 2 == 0

    #   options = {}
    #   args.each_slice(2) { |key_value| options[key_value[0]] = key_value[1] }

    #   return pkg, options
    # end

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
        self.patch_tables
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
      property  :forbidden,   Flag[ *methods ], :default => [ :post, :options ]
###   TODO: add this
###   property  :retired,     Boolean, :default  => true

      has n,    :package_record, :constraint => :destroy

      validates_uniqueness_of :filesystem, :scope => :hostname    # TODO: doesn't seem to work

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

      # TODO: only allow certain transitions.
      # TODO: put some tests for these.
      # TODO: this doesn't belong here, maybe (used in do-tape)

      def make_tape_master
        self.state = :tape_master
        self.save!
      end

      def possible_methods
        case state
        when :disk_master                         # Now a disk-based silo can do any of these: GET, PUT, DELETE
          [ :delete, :get, :put ]
        when :disk_idling, :disk_copied           # While here we're in the process of copying to tape; no changes permitted (GETs OK)
          [ :get ]
        when :tape_master                         # When entirely using tape we only allow individual GETs and DELETEs.
          [ :delete, :get ]
        else
          Raise "Unhandled state #{state} for silo #{self.hostname}:#{self.filesystem}."
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

    # PackageRecord keeps three kinds of records; PUT, DELETE, FIXITY.

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

        ## TODO: this isn't flexible enough - find actual repository we belong to - just repository enough?

        repository(repository).adapter.select(sql)
      end

    end # of class PackageRecord


    ### TODO: we want to populate the size field as well, need to add a size here, and 
    ### perhaps a latest_size on package record.  For now, we're just using the size info
    ### from package to ensure we're getting the functional interface correct - see the silo
    ### mixins for that....

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

      # gets either a package_record or silo_record, name as arguments

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
    end # of class HistoryRecord

    
    class ReservedDiskSpace 

      include DataMapper::Resource
      storage_names[:default] = 'reserved_disk_spaces'

      property  :id,          Serial
      property  :partition,   String,   :required => true, :index => true, :length => 255
      property  :timestamp,   DateTime, :required => true, :index => true, :default  => lambda { |resource, property| DateTime.now }
      property  :size,        Integer,  :required => true, :index => true, :min => 0, :max => 2**63 - 1      

      # remove all records from the database older than +max_reservation+.
      # +max_reservation+ is expressed in days - typically this is a few hours at most

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
