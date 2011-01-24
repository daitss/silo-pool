$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib'))

require 'datyl/tables'
require 'store/exceptions'
require 'lib/spec_helpers'

def psql_defs 
  File.join(File.dirname(__FILE__), '../tools/ddl.psql')
end

def mysql_defs
  File.join(File.dirname(__FILE__), '../tools/ddl.mysql')
end


# We'll use the SilosTable to test the general Table class; tests
# specific to the SilosTable have their own describe section.  Here we
# test the general ability to select, insert, update and delete
# records; to quote strings, and to provide rudimentary transaction
# support.

share_examples_for "Table class using any database" do

  it "should let us create and save a new silo record" do
    table  = SilosTable.new @db
    
    rec = table.new_record

    rec.hostname   = 'localhost'
    rec.filesystem = '/daitssfs/001'

    table.insert(rec).should == true
  end

  it "should allow us to retrieve a silo record" do

    table = SilosTable.new @db
    recs = table.select

    recs.length.should == 1
  end

  it "should allow us to retreive a silo record using a block" do
    table = SilosTable.new @db

    rec = nil
    table.select do |r|
      rec.should == nil   # we only expect one record at this point
      rec = r
    end
    
    rec.id.should == 1
  end

  it "should allow us to get a count of the records"   do
    table = SilosTable.new @db
    rec = table.new_record
    rec.hostname   = 'localhost'
    rec.filesystem = '/daitssfs/002'
    table.insert rec

    table.count.should == 2
    table.count("filesystem = '/daitssfs/002'").should == 1
  end

  it "should allow us to get list of the ids of the records"   do
    table = SilosTable.new @db
    ids = table.ids 

    ids.include?(1).should == true
    ids.include?(2).should == true
    ids.length.should == 2
  end

  it "should allow us to update a record" do
    table = SilosTable.new @db

    rec = table.select("filesystem = '/daitssfs/001'").pop

    rec.filesystem.should == '/daitssfs/001'

    rec.filesystem = '/daitssfs/003'
    table.update rec

    table.select("filesystem = #{table.quote('/daitssfs/001')}").count.should == 0    
  end

  it "should allow us to retrieve silo records with a subset of the columns" do
    table = SilosTable.new @db, 'filesystem'
    record = table.select.pop
    record.respond_to?('filesystem').should == true
    record.respond_to?('hostname').should   == false
  end
    
  it "should allow us to delete silo records from a table" do
    table  = SilosTable.new @db
    table.delete.should > 0
    table.select.count.should == 0
  end

  it "should properly quote strings for inserts" do
    table = SilosTable.new @db

    str = "O'Reilly's FileSystem"

    rec = table.new_record

    rec.filesystem = str
    rec.hostname   = 'localhost'
    
    table.insert rec

    rec = table.select("filesystem = #{table.quote(str)}").pop
    rec.filesystem.should  == str
  end

  def add_some_silo table
    rec = table.new_record
    rec.filesystem = some_name
    rec.hostname   = some_name
    table.insert rec
  end

  it "should roll back transactions if an error occurs" do

    table = SilosTable.new @db

    first_set = table.select.sort { |a,b| a.id <=> b.id }
    add_some_silo table
    second_set = table.select.sort { |a,b| a.id <=> b.id }
    
    first_set.should_not == second_set  # make sure add_some_silo works as expected

    begin
      @db.transact do
        add_some_silo table
        raise "an error occurs.."
      end
    rescue Store::DataBaseTransactionError => e
      raise e unless e.message == "an error occurs.."   # if it's not our error, we've got a bug somewhere...
    end

    third_set = table.select.sort { |a,b| a.id <=> b.id }
    second_set.should == third_set
  end


end # of share_examples_for "Table class using any database"


describe "Table class using MySQL" do
  before(:all) {  @ms = MysqlMaker.new(mysql_defs, '-uroot');   @db = @ms.connect('root') }
  after(:all)  {  @ms.drop }

  it_should_behave_like "Table class using any database"
end

describe "Table class using Postgres" do
  before(:all) { @ps = PostgresMaker.new(psql_defs);  @db = @ps.connect('fischer') }
  after(:all)  { @ps.drop }

  it_should_behave_like "Table class using any database"
end



share_examples_for "SilosTable using any database" do

  it "should allow us to create and save a silo record" do
    rec = @silos_table.new_record
    rec.hostname   = 'localhost'
    rec.filesystem = '/daitssfs/001'
    lambda { @silos_table.insert(rec) }.should_not raise_error
  end

  it "should default values properly for a newly-created silo record" do

    rec = @silos_table.select.pop

    rec.id.should            == 1
    rec.filesystem.should    == '/daitssfs/001'
    rec.hostname.should      == 'localhost'
    rec.state.should         == 'disk_master'
    rec.version.should       == 1
    rec.forbid_get.should    == 0
    rec.forbid_delete.should == 0
    rec.forbid_put.should    == 0
    rec.forbid_post.should   == 0
  end

  it "should not allow us to insert a record with an existing hostname/filsesystem" do

    rec = @silos_table.new_record
    rec.hostname   = 'localhost'
    rec.filesystem = '/daitssfs/001'
    lambda { @silos_table.insert(rec) }.should raise_error Store::DataBaseError
  end

end # of share_examples_for "SilosTable using any database"


describe "SilosTable using MySQL" do
  before(:all) do
    @ms = MysqlMaker.new(mysql_defs, '-uroot')
    @silos_table = SilosTable.new(@ms.connect('root'))
  end

  after(:all) do
    @ms.drop
  end

  it_should_behave_like "SilosTable using any database"
end


describe "SilosTable using Postgres" do

  before(:all) do
    @ps = PostgresMaker.new(psql_defs)
    @silos_table = SilosTable.new(@ps.connect('fischer'))
  end

  after(:all) do
    @ps.drop
  end

  it_should_behave_like "SilosTable using any database"
end


share_examples_for "PackagesTable using any database" do

  it "should allow us to create and save a package record" do

    rec = @packages_table.new_record

    rec.silo_id           = @silo.id
    rec.size              = 42
    rec.type              = 'octet-stream'
    rec.initial_sha1      = some_sha1
    rec.initial_md5       = some_md5
    rec.initial_timestamp = Time.now
    rec.name              = 'E19561201_BIRDAY'

    lambda { @packages_table.insert(rec) }.should_not raise_error
  end

  it "should default values properly for a newly-created silo record" do

    rec = @packages_table.select.pop

    rec.id.should == 1
  end

  it "should not allow us to insert a record with an existing hostname/filsesystem" do

    rec = @packages_table.new_record

    rec.silo_id           = @silo.id
    rec.type              = 'octet-stream'
    rec.size              = 1000
    rec.initial_sha1      = some_sha1
    rec.initial_md5       = some_md5
    rec.initial_timestamp = Time.now
    rec.name              = 'E19561201_BIRDAY'

    lambda { @packages_table.insert(rec) }.should raise_error Store::DataBaseError
  end

  it "should not allow us to insert a record with a bogus silo id" do

    rec = @packages_table.new_record

    rec.silo_id           = 1000000
    rec.type              = 'octet-stream'
    rec.size              = 1000
    rec.initial_sha1      = some_sha1
    rec.initial_md5       = some_md5
    rec.initial_timestamp = Time.now
    rec.name              = some_name

    lambda { @packages_table.insert(rec) }.should raise_error Store::DataBaseError
  end

  it "should delete the package record when the parent silo record is deleted" do
    
    some_silo_id  = @packages_table.select.pop.silo_id

    @packages_table.select("silo_id = #{some_silo_id}").count.should > 0
    @silos_table.delete("id = #{some_silo_id}").should > 0
    @packages_table.select("silo_id = #{some_silo_id}").count.should == 0
  end

end # of share_examples_for "PackagesTable using any database"

describe "PackagesTable using MySQL" do
  before(:all) do
    @ms = MysqlMaker.new(mysql_defs, '-uroot')

    conn = @ms.connect('root')
    @packages_table = PackagesTable.new(conn)
    @silos_table    = SilosTable.new(conn)
    rec = @silos_table.new_record
    rec.hostname   = 'localhost'
    rec.filesystem = '/001'
    @silos_table.insert rec
    @silo = @silos_table.select.pop
  end

  after(:all) do
    @ms.drop
  end

  it_should_behave_like "PackagesTable using any database"
end


describe "PackagesTable using Postgres" do

  before(:all) do
    @ps = PostgresMaker.new(psql_defs)
    conn = @ps.connect('fischer')

    @packages_table = PackagesTable.new(conn)
    @silos_table    = SilosTable.new(conn)

    rec = @silos_table.new_record
    rec.hostname   = 'localhost'
    rec.filesystem = '/001'
    @silos_table.insert rec
    @silo = @silos_table.select.pop
  end

  after(:all) do
    @ps.drop
  end

  it_should_behave_like "PackagesTable using any database"
end
