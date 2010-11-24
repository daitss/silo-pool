# require 'store/tables'
require 'digest/md5'
require 'digest/sha1'
require 'fileutils'
require 'socket'
require 'yaml'

# Common routines for db_spec, silo_spec, silodb_spec, and silotape_spec (maybe table classes as well)


# Helpers for tables class spec tests.

class DbMaker
  attr_reader :name, :db

  def initialize
    @name = 'spec_tests_' + sprintf("%04d", rand(10000).to_s)
  end

  def connect vendor, host, user, password, dbname
    @db = Connection.new(vendor, host, user, password, dbname)
    return db
  end

end

class MysqlMaker < DbMaker

  def initialize path, opts = ''
    super()
    `mysqladmin -uroot create #{name}`
    opts += " #{name}"
    mysql opts, File.read(path)
  end

  def connect  user, password = nil 
    return super('mysql', 'localhost', user, password, name)
  end

  def mysql(opts, text)
    IO.popen("mysql #{opts}", "w") { |io| io.puts text }
  end

  def drop
    db.close
    `echo drop database #{name} | mysql -uroot`
  end
end

class PostgresMaker < DbMaker
  
  def initialize path, opts = ''
    super()
    `createdb #{name}`
    opts += name
    psql opts, File.read(path)
  end

  def connect user, password = nil
    return super('postgres', 'localhost', user, password, name)
  end

  def psql(opts, text)
    IO.popen("psql --quiet #{opts} 2> /dev/null", "w") { |io| io.puts text }
  end

  def drop
    db.close
    `dropdb #{name}`
  end
end






def my_host
  Socket.gethostname
end

@@base = Time.now.strftime("%Y%m%d_AAAAAA")

def some_name
  (@@base.succ!).clone
end

def some_data
  data = "Some test data: " + rand(100000000).to_s + "\n"
end

def some_sha1
  Digest::SHA1.hexdigest("Some test data: " + rand(100000000).to_s + "\n")
end

def some_md5
  Digest::MD5.hexdigest("Some test data: " + rand(100000000).to_s + "\n")
end

# sh = SubtractableHash.new(1 => :a, 2 => :b, 3 => :c)  # returns { 1 => :a, 3 => :c, 2 => :b }, say.
# Then sh.minus(2) # returns { 1 => :a, 3 => :c }  without modifying the 'sh' object.

class SubtractableHash < Hash
  def initialize *args
    super
    self.merge! *args unless args.empty?
  end

  def minus key
    partial = self.clone
    partial.delete key
    partial
  end
end

def some_attributes
  hash = SubtractableHash.new  :sha1 => some_sha1, :md5 => some_md5, :timestamp => DateTime.now - rand(100), :size => rand(10000), :type => 'x-application/tar'
end

def recreate_database

  # We have db configuration data in a yaml file; it might look like:
  #
  # silo_spec_test:   { vendor: mysql, hostname: localhost, database: silo_spec_test, username: root, password: }
  #
  # We expect a silo_spec_test, and expect to be able to drop and recreate the tables via DM.automigrate!

  yaml_filename = '/opt/fda/etc/db.yml'  

  if not (File.exists?(yaml_filename) and File.readable?(yaml_filename))
    pending "Can't contine - see the comments in 'def recreate_database' in #{__FILE__} to fix this"
  end

  DB.setup yaml_filename, 'silo_spec_test'
  DB::DM.automigrate!
end
