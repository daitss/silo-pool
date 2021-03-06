require 'digest/md5'
require 'fileutils'
require 'optparse'
require 'ostruct';
require 'sys/filesystem'
require 'yaml'

# You know the drawer in your kitchen that has all the junk in it?  This module is like that...

module StoreUtils

  def StoreUtils.disk_id(path)
    File.stat(path).dev
  end

  def StoreUtils.disk_size(path)
    fs = Sys::Filesystem.stat(path)
    fs.fragment_size * fs.blocks    # fragment_size is used in preference to block_size, which is just the OS's preference
  end
  
  def StoreUtils.disk_free(path)
    fs = Sys::Filesystem.stat(path)
    fs.fragment_size * fs.blocks_available  # blocks_available < blocks_free;  some are reserved for root.
  end
  
  def StoreUtils.strip_trailing_slash_maybe(string)
    return string if string.length == 1
    return string.gsub(/#{File::SEPARATOR}+$/, "")
  end

  def StoreUtils.valid_ieid_name? string
     string =~ /^E20\d{2}[0-1]\d[0-3]\d_[A-Z]{6}$/ ? true : false
  end 

  def StoreUtils.xml_escape str
    str.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub("'", '&apos;').gsub('"', '&quot;')
  end

  def StoreUtils.csv_escape str
    '"' + str.gsub('"', '""') + '"'   # 'fo,o"bar' =>  '"fo,o""bar"'
  end

  # FIXME: Plenty of ways for disk_mount_point to go wrong: SMBFS mounted directory. Symbolic link somewhere.
  # Be careful out there...  
  
  # N.B. We depend on a trailing slash being removed in path
  
  def StoreUtils.disk_mount_point(path)
    path = File.expand_path(path)
    path = File.dirname(path) unless File.directory? path
    path = path.gsub(%r{/+$}, '')
    
    id = disk_id path
    components = path.split File::SEPARATOR  # break into path components and remove leading empty string
    components.shift
    
    topdown = File::SEPARATOR
    components.each do |c|
      return strip_trailing_slash_maybe(topdown) if disk_id(topdown) == id
      topdown += c + File::SEPARATOR
    end
    return strip_trailing_slash_maybe(topdown)
  end
  
  # We need to provide the base64 of the original binary md5 checksum; however 
  # we typically have only the hexstring.  This funtion takes the hexstring, packs it
  # into the binary representation, then encodes that into a base64 representation.

  def StoreUtils.md5hex_to_base64(hexstring)
    return nil unless hexstring.length == 32
    [hexstring.scan(/../).pack("H2" * 16)].pack("m").chomp
  end

  # This function does the reverse of the above, taking the base64 string and returning
  # the corresponding hex string.

  def StoreUtils.base64_to_md5hex(string)
    return nil unless (string.class == String and string.length == 24)
    string.unpack("m")[0].unpack("H2" * 16).join
  end

  # StoreUtils.get_silo_options ARGS
  #
  # Parse the command line argments used for various silo fixity
  # utility programs.  Returns nil on error, after having written a
  # message on STDERR (usually you just want to exit with a non-zero
  # exit status on a nil return); on success returns a struct with the
  # following
  #
  #  * silo_path PATH (required) - the root of the filesystem with the silo, e.g. /daitss/016/; it must be readable (and currently writable, though that's a design flaw)
  #  * hostname  NAME (required) - the name of the host associated with this silo.
  #  * db_configuration_file FILEPATH (defaults to /opt/fda/etc/db.yml) - the path to a yaml file that provides db information
  #  * db_configuration_key STRING (required) - a key into the hash provided by reading the db_configuration_file, which will return a hash of db connection information.
  #  * syslog_facility FACILITY_CODE (optional) - if provided you should setup syslog to this facility, otherwise logging to STDERR

  def StoreUtils.get_silo_options args
    conf = OpenStruct.new(:hostname => nil, :silo_path => nil, :syslog_facility => nil,
                          :db_configuration_key => nil, :db_configuration_file => '/opt/fda/etc/db.yml')

    opts = OptionParser.new do |opts|
      
      opts.on("--silo-path PATH",  String, "The root of the filesystem with the silo, e.g. '/daitssfs/001/'")  do |path|
        conf.silo_path = path
        if not File.directory? path
          raise "The silo-path supplied, #{path}, is not a directory." 
        end
        if not File.writable? path
          raise "The silo-path supplied, #{path} is owned by #{StoreUtils.user(path)} and is not writable by this process, which is running as user #{StoreUtils.user}."
        end
      end
      
      opts.on("--syslog-facility FACILITY",  String, "The facility in syslog to log to, otherwise log to STDERR") do |facility|
        conf.syslog_facility = facility
      end
      
      opts.on("--db-configuration-file PATH",  String, "A database yaml configuration file, defaults to #{conf.db_configuration_file}") do |path|
        conf.db_configuration_file = path
      end
      
      opts.on("--db-configuration-key KEY",  String, "The key for the database information in the database yaml configuration file #{conf.db_configuration_file}") do |key|
        conf.db_configuration_key = key
      end
      
      opts.on("--hostname HOST",   String, "The name of the host this silo is associated with (usually a virtual host)") do |hostname|
        conf.hostname = hostname.downcase
      end
    end
    opts.parse!(args) 
    raise "No path provided"      unless conf.silo_path
    raise "No hostname provided"  unless conf.hostname
    raise "No key into the DB configuration file (#{conf.db_configuration_file}) provided" unless conf.db_configuration_key
    raise "Default yaml file #{conf.db_configuration_file} not found" unless File.exists? conf.db_configuration_file
    
  rescue => e
    STDERR.puts e, opts
    return nil
  else
    return conf
  end

  def StoreUtils.hashpath name
    md5  =  Digest::MD5.hexdigest name
    File.join(md5[0..2], md5[3..-1])      
  end

  def StoreUtils.hashpath_parent name
    Digest::MD5.hexdigest(name)[0..2]
  end

  
  # Without argument, give the name of the user running this process
  # as a string.  With argument PATH, a string, assume it is a
  # readable filepath and return the user name who owns it as a
  # string.

  def StoreUtils.user path = nil
    if path.nil?
      Etc.getpwuid(Process.uid).name
    else
      Etc.getpwuid(File.stat(path).uid).name
    end
  end

  # Without argument, return the group of the user running this
  # process as a string.  With argument PATH, a string, assume it is a
  # readble filepath and return the group name who owns it as a
  # string.

  def StoreUtils.group path = nil
    if path.nil? 
      Etc.getgrgid(Process.gid).name
    else
      Etc.getgrgid(File.stat(path).uid).name
    end
  end

  # put in commas in a number (American style numeric format)

  def StoreUtils.commify num
    num.to_s.gsub(/(\d)(?=(\d\d\d)+(?!\d))/, "\\1,")
  end

  # Given a directory, return a path to a PID file in it, naming based on the currently running process name

  def StoreUtils.pid_file dir
    File.join(dir, $0.split(File::SEPARATOR).pop + '.pid')
  end

  # Purpose here is to provide connections for datamapper using our yaml configuration file + key technique;
  # This will probably go away.

  def StoreUtils.connection_string yaml_file, key

    oops = "Database setup can't"

    # This looks like excessive error checking, but configuration errors need a lot explanation for new users of DAITSS.

    begin
      dict = YAML::load(File.open(yaml_file))
    rescue => e
      raise "#{oops} parse the configuration file '#{yaml_file}': #{e.message}."
    end

    raise "#{oops} parse the data in the configuration file '#{yaml_file}'." if dict.class != Hash

    dbinfo = dict[key]
    raise "#{oops} get any data from the configuration file '#{yaml_file}' using the key '#{key}'"                                     unless dbinfo
    raise "#{oops} get the vendor name (e.g. 'mysql' or 'postgres') from the configuration file '#{yaml_file}' using the key '#{key}'" unless dbinfo.include? 'vendor'
    raise "#{oops} get the database name from the configuration file '#{yaml_file}' using the key '#{key}'"                            unless dbinfo.include? 'database'
    raise "#{oops} get the host name from the configuration file '#{yaml_file}' using the key '#{key}'"                                unless dbinfo.include? 'hostname'
    raise "#{oops} get the user name from the configuration file '#{yaml_file}' using the key '#{key}'"                                unless dbinfo.include? 'username'

    # Example string: 'mysql://root:topsecret@localhost/silos'
    # TODO: support different ports

    return \
      dbinfo['vendor']    + '://' +                                   # mysql://
      dbinfo['username']  +                                           # mysql://fischer
     (dbinfo['password']  ? ':' + dbinfo['password'] : '') + '@' +    # mysql://fischer:topsecret@  (or mysql://fischer@)
      dbinfo['hostname']  +
     (dbinfo['port']      ? ':' + dbinfo['port'].to_s : '')  + '/' +  # mysql://fischer:topsecret@localhost/ (or mysql://fischer:topsecret@localhost:port/)
      dbinfo['database']                                              # mysql://fischer:topsecret@localhost/store_master
  end



  # Remove the password from the db connection string for logging

  def StoreUtils.safen_connection_string str

    vendor, rest = str.split('://', 2)              # postgres://fischer:topsecret@example.org:5432/mydb => [ postgres, fischer:topsecret@example.org:5432/mydb ]
    return str unless rest

    userinfo, host_and_db = rest.split('@', 2)      # fischer:topsecret@example.org:5432/mydb => [ fischer:topsecret, example.org:5432/mydb ]
    return str unless host_and_db

    user, pass = userinfo.split(':', 2)             # fischer:topsecret => [ fischer, topsecret ]
    return str unless pass

    return vendor + '://' + user + ':********@' + host_and_db
  end

end # of Module StoreUtils
