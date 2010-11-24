#!/usr/bin/env ruby

# $LOAD_PATH.unshift "/Users/fischer/WorkProjects/daitss2/composite-tape-disk/lib"
# $LOAD_PATH.unshift "/Users/fischer/WorkProjects/daitss2/composite-tape-disk/spec"

# require 'spec_helpers'
require 'lib/spec_helpers'
require 'store/exceptions'

DEBUG = true

# TODO: try to make sure server and client are in UTF-8 mode.
# mysql: dbh.character_set_name  returns - dbh.options(opt, val=nil)  ???

# Built for speed, not comfort.  If you don't like SQL, these classes
# are not for you.  Selects are pretty fast, while individual record
# updates and inserts are relatvely slow.  Makes these assumptions:
# the tables have primary key 'id' and integer 'version' fields.
# Assumes 'id' will be autoincremented, while 'version' should be an
# integer that defaults to 1. The 'version' field is used to implement
# optimistic locking.
#
# Currently supports MySQL and Postgres.  Sqlite and Oracle should be easy enough.
#
# Very few type coercians go on here; for the select function, we cast
# mysql integers and postgress integer, bigint and booleans to ruby
# fix/bignums on reads. These are expensive: don't include these
# fields in object instantiations for your app if you don't need them.
#
# The timestamps I've used in my tables are all UTC (and you should
# probably do that too).  That means you'll have to do some special
# parsing when casting them to time objects.  For example:
#
#   require 'time'
#   timestamp = "2008-05-24 15:48:47"
#   time = Time.gm(*(timestamp.split(/[:\s-]+/).map{|a| a.to_i})) => 'Sat May 24 15:48:47 UTC 2008'
#   time.zone        => 'UTC'
#   time.localtime   => 'Sat May 24 11:48:47 -0400 2008'
#   time.zone        => 'EDT'

# The structs we created need unique names - this allows us to use an incremented value.

class ConnectionId
  @@id = 0
  def self.next
    @@id += 1
  end
end

# ConnectionsMixins will have access to dbh, hostname, username, database, password, vendor
# when they are called.

# We'll have dbh, hostname, password, and database defined in the
# class we're mixed into.
#
# We keep our data in 'field' order.  For a given table, we have
# a list of fields associated with that table, which is used explicitly
# for selects, for creating the returned record structs, etc.



class Connection

  attr_reader :hostname, :username, :database, :password, :vendor, :dbh

  def initialize vendor, hostname, username, password, database

    @vendor = vendor.downcase

    case vendor    # mix in vendor-specific connect, close, and transact  methods

    when 'mysql'
      require 'mysql'
      extend MySqlConnectionMixIn

    when 'postgres'
      require 'pg'
      extend PostgressConnectionMixIn

    else
      raise Store::ConfigurationError, "Unsupported database #{vendor}. Supported databases: 'mysql', 'postgres'."
    end

    @hostname = hostname
    @username = username
    @password = password
    @database = database
    connect

  rescue LoadError => e
    raise Store::ConfigurationError, "Unable to load #{vendor} module. Perhaps it hasn't been installed on this host."
  end
end


module MySqlConnectionMixIn

  attr_reader :dbh

  def connect
    @dbh = Mysql.real_connect(hostname, username, password, database)
    dbh.reconnect = true
    dbh
  end

  def reconnect
    connect
  rescue => e  # ignore, we'll take care of errors elsewhere
  end

  def close
    dbh.close
  end

  def transact
    dbh.autocommit(false)
    yield
  rescue => e
    dbh.rollback
    raise Store::DataBaseTransactionError, e.message
  else
    dbh.commit
  ensure
    dbh.autocommit(true)
  end

end

module PostgressConnectionMixIn

  attr_reader :dbh

  def connect
    @dbh = PGconn.connect(hostname, nil, nil, nil, database, username, password)
  end

  def close
    dbh.finish
  end

  ## TODO: figure out how to reconnect on error.

  def transact
    dbh.transaction do |conn|
      yield
    end
  rescue => e
    raise Store::DataBaseTransactionError, e.message
  end
end



# TableMixIns will have access to dbh, table_name attributes of their underlying classes.

module PostgresTableMixIn

  def _get_fields name_of_table
    res = dbh.query("SELECT * FROM #{name_of_table} LIMIT 0")
    res.fields
  end

  def _escape string
    dbh.escape string
  end

  def _query query_string
####    STDERR.puts "_query: " + query_string if DEBUG

    res = dbh.query query_string
    rows = []

    (0 .. res.num_tuples - 1).each do |row_number|
      row = []
      (0 .. res.num_fields - 1).each do |col_number|
        row.push res.getvalue(row_number, col_number)
      end
      if block_given?
        yield row
      else
        rows.push row
      end
    end

    return rows unless block_given?
  ensure
    res.clear
  end

  # use for update, insert, delete: get a count back of the number of rows affected

  def _modify command
####    STDERR.puts "_modify: " + command if DEBUG
    res = dbh.query command
    res.cmd_tuples
  end


  # In field order, return information....

  def _build_data_dictionary table, fields

  #  Example field check for PostgreSQL for silos table; see the comments on the _build_data_dictionary MySQL method
  #  for the details on the silos table structure.
  #
  #    SELECT column_name, column_default, is_nullable, data_type FROM information_schema.columns WHERE table_name = 'silos';
  #
  #      column_name  |          column_default           | is_nullable |     data_type
  #    ---------------+-----------------------------------+-------------+-------------------
  #     id            | nextval('silos_id_seq'::regclass) | NO          | integer
  #     hostname      |                                   | NO          | character varying
  #     filesystem    |                                   | NO          | character varying
  #     state         | 'disk_master'::silo_state         | NO          | USER-DEFINED
  #     forbid_get    | false                             | NO          | boolean
  #     forbid_put    | false                             | NO          | boolean
  #     forbid_delete | false                             | NO          | boolean
  #     forbid_post   | false                             | NO          | boolean
  #     version       | 1                                 | YES         | integer

    data_dictionary = {}

    # note that dbh.query is not the same method as our class's query.

    res = dbh.query "SELECT column_name, column_default, is_nullable, data_type FROM information_schema.columns WHERE table_name = #{quote(table)}"

    (0 .. res.num_tuples - 1).each do |row|

      name        = res.getvalue(row, 0)
      nullable    = res.getvalue(row, 2) =~ /YES/i
      type        = res.getvalue(row, 3)

      data_dictionary[name] = {}

      data_dictionary[name][:name]             =  name

      data_dictionary[name][:integer?]         =  case type
                                                  when /boolean/;          false
                                                  when /integer|bigint/i;  true
                                                  else; false
                                                  end

      # casts are done on reading records only. They add significant overhead: don't specify fields you don't need

      data_dictionary[name][:cast]             =  case type
                                                  when /boolean/i;         lambda { |val| val =~ /^f|0/ ? 0 : 1 }
                                                  when /integer|bigint/i;  lambda { |val| val.to_i }
                                                  else; nil
                                                  end
    end
    return fields.map { |name| data_dictionary[name] }  # return array of info in field order
  end


  def _last_insert_id
    res = dbh.query "SELECT currval(#{quote(table_name + '_id_seq')})"
    return nil if res.num_tuples != 1
    res.getvalue(0,0).to_i
  end
end

module MySqlTableMixIn

  def _escape string
    dbh.escape_string string
  end

  def _get_fields name_of_table
    dbh.list_fields(name_of_table).fetch_fields.map { |f| f.name }
  end

  def _query query_string

####    STDERR.puts "_query: " + query_string  if DEBUG

    dbh.query_with_result = false    # Huh. May need to record this and reset it in ensure block
    dbh.query query_string
    res = dbh.use_result

    if block_given?
      while cols = res.fetch_row do
        yield cols
      end
    else
      list = []
      while cols = res.fetch_row do
        list.push cols
      end
      list
    end
    # TODO: clear res in ensure blcok
  end

  def _modify command
####    STDERR.puts "_modify: " + command  if DEBUG
    st  = dbh.prepare command
    st.execute
    st.affected_rows
  ensure
    st.close if st.respond_to? :close
  end

  # we Might need explicit table_name TABLE here to support joined tables.

  def _build_data_dictionary table, fields

    # MySQL provides a field object, these are some of the Mysql::Field methods output for the Silos table:
    #
    #  field object           decimals         def  flags is_not_null?  is_num? is_pri_key? length max_length table name
    #  ------------           --------         ---  ----- ------------  ------- ----------- ------ ---------- ----- ----
    #  <Mysql::Field:id>:            0           0  49699         true     true        true     10          0 silos id
    #  <Mysql::Field:hostname>:      0         nil  20489         true    false       false    127          0 silos hostname
    #  <Mysql::Field:filesystem>:    0         nil  20489         true    false       false    255          0 silos filesystem
    #  <Mysql::Field:state>:         0 disk_master  16649         true    false       false     11          0 silos state
    #  <Mysql::Field:forbid_get>:    0           0  32769         true     true       false      1          0 silos get
    #  <Mysql::Field:forbid_put>:    0           0  32769         true     true       false      1          0 silos put
    #  <Mysql::Field:forbid_delete>: 0           0  32769         true     true       false      1          0 silos delete
    #  <Mysql::Field:forbid_post>:   0           0  32769         true     true       false      1          0 silos post
    #  <Mysql::Field:version>:       0           1  49161         true     true       false     11          0 silos version
    #
    # The silos table was defined as below when the above docs where
    # generated (note that this definition is just for illustration of
    # this method - the actual DDL for the silos table will probably
    # drift from the below slightly)
    #
    #   id integer unsigned not null AUTO_INCREMENT,
    #   hostname       varchar(127) not null,
    #   filesystem     varchar(255) not null,
    #   state          enum('disk_master', 'disk_idling', 'disk_copied', 'tape_master')  default 'disk_master' not null,
    #   forbid_get     boolean    default false not null,
    #   forbid_put     boolean    default false not null,
    #   forbid_delete  boolean    default false not null,
    #   forbid_post    boolean    default false not null,
    #   version        integer    default 1 not null,
    #   primary key (id),
    #   unique (hostname, filesystem),
    #

    records_by_field_name = {}

    dbh.list_fields(table).fetch_fields.each do |field|
      rec = {}
      rec[:name]             = field.name
      rec[:integer?]         = field.is_num?
      rec[:cast]             = field.is_num? ? lambda { |val| val.to_i } : nil
      
      records_by_field_name[field.name] = rec
    end

    data_dictionary = fields.map { |fn| records_by_field_name[fn] }

    return data_dictionary
  end

  def _last_insert_id
    dbh.insert_id
  end
end


class Table

  attr_reader   :table_name, :dbh, :record_constructor, :fields, :data_dictionary

  def initialize connection, table_name, *fields

    @dbh  = connection.dbh
    @table_name  = table_name

    # bring in _quote, _query and _fields, transact block, etc, etc

    case connection.vendor
    when 'postgres'
      extend PostgresTableMixIn
    when 'mysql'
      extend MySqlTableMixIn
    else
      raise Store::ConfigurationError, "Unsupported database #{connection.vendor}. Supported databases: 'mysql', 'postgres'."
    end

    if fields.empty?
      @fields = _get_fields(@table_name)
    else
      @fields = fields.map { |f| f.to_s }
    end

    @fields.unshift 'version' unless @fields.include? 'version'   # we always need these
    @fields.unshift 'id'      unless @fields.include? 'id'

    struct_name = connection.vendor.capitalize + '_' + ConnectionId.next.to_s + '_' + table_name.capitalize

    @record_constructor = Struct.new(struct_name, *(@fields.map{ |f| f.gsub('.', '_')}))
    @data_dictionary    = _build_data_dictionary table_name, @fields

    # Ensure our connection works up front

    begin
      raise Store::ConfigurationError, "Can't connect to #{vendor} database #{database}" unless (_query("SELECT 1+1").flatten.pop.to_i == 2)
    rescue => e
      raise Store::ConfigurationError, e.message
    end

  end

  # Return an empty record for an insert. Beware setting the ID - most always you'll want to leave it empty.
  # Most fields default to :undefined and will not be used in an update or insert.  Set what you need to.

  def new_record
    rec =@record_constructor.new
    rec.members.each { |field| rec[field] = :undefined }
    rec
  end

  def select where = nil, order = nil, limit = nil

    procs = data_dictionary.map { |rec| rec[:cast] }         # array of cast procs or nils, in field order.
    needs_cast = []
    procs.each_index { |i| needs_cast.push(i) if procs[i] }  # column indexes of procs from above we'll need to apply.

    sql =  "SELECT #{fields.join(', ')} FROM #{table_name}" + clauses(where, order, limit)

    if block_given?
      _query(sql) do |row|
        needs_cast.each { |i| row[i] = (row[i].nil? ? nil : procs[i].call(row[i])) }
        yield  @record_constructor.new(*row)
      end

    else
      list = []
      _query(sql).each do |row|
        needs_cast.each { |i| row[i] = (row[i].nil? ? nil : procs[i].call(row[i])) }
        list.push @record_constructor.new(*row)
      end
      return list
    end
  end

  def delete where = nil
    _modify "DELETE FROM #{table_name}" + clauses(where, nil, nil)
  end

  # count [ where-clause ] [ order-clause ] [ limit-clause ]
  #
  # Count the records to be returned for given conditions.

  def count where = nil, order = nil, limit = nil
    # query returns something like [ ['number'] ]
    query("SELECT COUNT(*) FROM #{table_name}" + clauses(where, order, limit))[0].pop.to_i
  end

  # ids [ where-clause ] [ order-clause ] [ limit-clause ]
  #
  # Return the ids for the given conditions; useful for sub-selects.

  def ids where = nil, order = nil, limit = nil
    # query returns something like [ ['id-1'], ['id-2'] ... ]
    query("SELECT id FROM #{table_name}" + clauses(where, order, limit)).flatten.map { |id| id.to_i }
  end

  def update record

    keys, vals = prep(record, 'id', 'version')

    raise "No version set in this record. Did you mean to do an insert here?" if record.version == :undefined

    keys.push 'version'
    vals.push record.version + 1

    settings = (keys.zip vals).map { |key, val| "#{key}=#{val}" }.join(", ")

    number_affected = _modify "UPDATE #{table_name} SET #{settings} WHERE id=#{record.id} and version=#{record.version}"

    if number_affected == 1
      record.version = record.version + 1
      true
    else
      false
    end
  end

  # id and version should not, in general, be set on these;

  def insert record

    keys, vals = prep(record, 'id')

    number_affected = _modify "INSERT INTO #{table_name}(#{keys.join(', ')}) VALUES(#{vals.join(', ')})"

    # could we get the id from this?  We lose track of our default values.

    if number_affected == 1
      record.version = 1
      record.id = _last_insert_id
      true
    else
      false
    end

  rescue PGError => e
    raise Store::DataBaseError, "Postgres Insert error: #{e.message}"
  rescue => e
    raise Store::DataBaseError, "Insert error: #{e.message}"
  end

  def quote string
    return 'NULL' if string.nil?
    return 'NULL' if string =~ /^NULL$/i
    return "'" + _escape(string.to_s) + "'"
  end

  private

  # 'WHERE     expects a string that gives conditions, e.g. "filesystem like '%silos%' AND id < 100"
  # 'ORDER BY' e.g. "field DESC" or "field1, field2"
  # 'LIMIT'    expects a string like "<number>" or even "<number> OFFSET <start>" (sqlite, postgress, mysql extension)

  def clauses where, order, limit
    phrase = [ (where ? "WHERE #{where}"    : nil),
               (order ? "ORDER BY #{order}" : nil),
               (limit ? "LIMIT #{limit}"    : nil) ].compact.join(" ")

    phrase.empty?  ? '' : ' ' + phrase
  end

  # Query is for rapid return of array of arrays; normally you'll want to use select.

  def query query_string
    if block_given?
      _query(query_string) { |row| yield row }
    else
      rows = []
      _query(query_string) { |row| rows.push row }
      return rows
    end
  end


  # Quote the elements in a record as necessary.  Return two arrays: a subset of the field names, and values, possibly quoted.

  def prep record, *discards

    keys = []
    vals = []
    data_dictionary.each do |info|  # we get these in field order
      field_name = info[:name]
      next if record[field_name] == :undefined  # new records are born with this default.
      next if discards.include? field_name
      keys.push field_name
      if record[field_name].nil?
        vals.push 'NULL'
      else
        vals.push info[:integer?] ? record[field_name].to_i : quote(record[field_name])
      end
    end

    return keys, vals
  end

  # Assumes we have a version and id field.

end # of class Table


# Simple left inner join;  to do: add update/inserts in a transaction - let the first specified
# table have any preconditions.

class EquiJoinTable < Table

  attr_reader  :table1_name, :table2_name, :dbh, :record_constructor, :join1, :join2, :fields, :fields1, :fields2, :data_dictionary

  def initialize connection, table1_name, table2_name, join1, join2, fields1 = [], fields2 = []

    @dbh  = connection.dbh
    @table1_name  = table1_name
    @table2_name  = table2_name
    @join1 = join1.to_s
    @join2 = join2.to_s

    # bring in _escape, _query and _fields

    case connection.vendor
    when 'postgres'
      extend PostgresTableMixIn
    when 'mysql'
      extend MySqlTableMixIn
    else
      raise "Unsupported database #{connection.vendor}. Supported databases: 'mysql', 'postgres'."
    end

    @fields1 =  _get_fields(table1_name)  if fields1.empty?
    @fields2 =  _get_fields(table2_name)  if fields2.empty?

    @fields = @fields1.map { |f| table1_name + '.' + f.to_s }  +  @fields2.map { |f| table2_name + '.' + f.to_s }

    recname = connection.vendor.capitalize  + '_' + ConnectionId.next.to_s + '_' + table1_name.capitalize + '_' + table2_name.capitalize

    @record_constructor = Struct.new(recname, *(@fields.map{ |f| f.gsub('.', '_')}))   # don't use dots in record constructor

    ddl1 = _build_data_dictionary(table1_name, @fields1)
    ddl2 = _build_data_dictionary(table2_name, @fields2)

    ddl1.each { |rec| rec[:name] = table1_name + '.' + rec[:name] }
    ddl2.each { |rec| rec[:name] = table2_name + '.' + rec[:name] }

    @data_dictionary = ddl1 + ddl2

    # Ensure our connection works up front

    begin
      raise Store::ConfigurationError, "Can't connect to #{vendor} database #{database}" unless (_query("SELECT 1+1").flatten.pop.to_i == 2)
    rescue => e
      raise Store::ConfigurationError, e.message
    end

  end

  # SELECT requires a block, and does minimal type casting - integers, boolean strings to fixnums (or bignums)

  def select where = nil, order = nil, limit = nil

    phrase =  "SELECT #{fields.join(', ')} " +
                "FROM #{table1_name}, #{table2_name} " +
               "WHERE #{table1_name}.#{join1} = #{table2_name}.#{join2}" +
               clauses(where, order, limit).sub(/WHERE/i, "AND")

    procs = data_dictionary.map { |rec| rec[:cast] }         # array of cast procs or nils, in field order.
    needs_cast = []
    procs.each_index { |i| needs_cast.push(i) if procs[i] }  # column indexes of procs we'll need to apply.
    

    if block_given?
      _query(phrase) do |row|
        needs_cast.each { |i| row[i] = (row[i].nil? ? nil : procs[i].call(row[i])) }
        yield  @record_constructor.new(*row)
      end
    else
      list = []
      _query(phrase) do |row|
        needs_cast.each { |i| row[i] = (row[i].nil? ? nil : procs[i].call(row[i])) }
        list.push @record_constructor.new(*row)
      end
      list
    end
  end

  def update
    raise NotImplementedError
  end

  def insert
    raise NotImplementedError
  end

end # of class EquiJoinTable


class SilosTable < Table
  def initialize connection, *fields
    super(connection, 'silos', *fields)
  end
end

class PackagesTable < Table
  def initialize connection, *fields
    super(connection, 'packages', *fields)
  end
end

class HistoriesTable < Table
  def initialize connection, *fields
    super(connection, 'histories', *fields)
  end
end

class SiloLogsTable < Table
  def initialize connection, *fields
    super(connection, 'silo_logs', *fields)
  end
end

class SiloPackagesTable < EquiJoinTable
  def initialize connection, silos_fields = [], packages_fields = []
    super(connection, 'silos', 'packages', 'id', 'silo_id', silos_fields, packages_fields)
  end
end
