$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), 'lib'))  # for spec_helpers

require 'store/silo'
require 'fileutils'
require 'tempfile'
require 'find'

require 'spec_helpers'


describe Store::Silo do

  before do
    @silo_root = "/tmp/test-silo"
    FileUtils::mkdir @silo_root

    FileUtils::mkdir_p @silo_root + "/in"
    FileUtils::mkdir @silo_root + "/out"
    FileUtils::mkdir @silo_root + "/test"

    @silo     = Store::Silo.new @silo_root + "/test"
    @out_silo = Store::Silo.new @silo_root + "/out"
    @in_silo  = Store::Silo.new @silo_root + "/in"
  end
  
  after do
    Find.find(@silo_root) do |filename|
      File.chmod(0777, filename)
    end
  FileUtils::rm_rf @silo_root
  end
  
  it "should create a silo based on a directory" do
    expect{ Store::Silo.new @silo_root }.not_to raise_error
  end
=begin 
#
#commented out see the comments in  lib/store/silo.rb .  initialize method
#
  it "should not create a silo on anything but a directory" do
    t = Tempfile.new('testtmp')
    regular_file = t.path
    lambda { Store::Silo.new regular_file }.should raise_error(Store::StorageError)
  end
=end
  it "should take a object name and some data to store an object" do
    name = "test object"
    data =  "some data"
    expect{ @silo.put name, data }.not_to raise_error
  end

  it "should find an existing object given an object name" do
    name = "test object"
    data = "some data"
    @silo.put name, data
    @silo.get(name).should == data
  end

  it "should return nil on a get of a non-existant object" do
    @silo.get("missing object").should be_nil
  end

  it "should store an object with slashes in the name" do
    name = "foo/bar/baz"
    data = "some data!"
    @silo.put name, data
    @silo.get(name).should == data
  end

  it "should store an object with dots in the name" do
    name = ".."
    data = "some data!"
    @silo.put name, data
    @silo.get(name).should == data
  end

  it "should not allow duplication of a name" do
    name = some_name
    data = some_data
    @silo.put name, data
    expect{@silo.put(name, data)}.to raise_error(Store::SiloResourceExists)
  end

  it "should have size for an object" do
    name = some_name
    data = some_data
    @silo.put name, data
    @silo.size(name).should_not be_nil
  end

  it "should generate an etag for an object" do
    name = some_name
    data = some_data
    @silo.put(name, data)
    @silo.etag(name).class.should == String
  end

  it "should raise StorageError on requests for size for non-existant objects" do
    name = some_name
    expect{@silo.size(name)}.to raise_error(Store::StorageError)
  end

  it "should return size of zero, empty string, and specific md5 checksum on reading a zero length file" do
    name = some_name
    data = ""
    @silo.put name, data

    @silo.size(name).should == 0
    @silo.get(name).should == ""
    @silo.md5(name).should == "d41d8cd98f00b204e9800998ecf8427e"
  end

  it "should default type to 'application/octet-stream" do
    name = some_name
    @silo.put(name, some_data)
    @silo.type(name).should == 'application/octet-stream'
  end

  it "should allow us to set a type" do
    name = some_name
    @silo.put(name, some_data, 'x-application/tar')    
    @silo.type(name).should == 'x-application/tar'
  end

  it "should provide last_access time, a DateTime object" do
    name = some_name
    @silo.put(name, some_data)
    @silo.last_access(name).class.should == DateTime
    (@silo.last_access(name) - DateTime.now).should be_within(0.0001).of(0)
  end

  it "should have date for an object" do
    name = "the name"
    data = "some data!"
    @silo.put name, data
    @silo.datetime(name).should_not be_nil    
  end

  it "datetime should raise an error if the object does not exist" do
    name = "bogus name"
    expect{ @silo.datetime(name)}.to raise_error(Store::StorageError)	
  end

  it "datetime should not raise error if the object does exist"	do
    name = "the name"
    data = "some data"
    @silo.put name, data
    expect{ @silo.datetime(name)}.not_to raise_error
  end

  it "datetime should return the time an object was created" do
    name = "the name"
    data = "some data!"
    @silo.put name, data
    t = @silo.datetime(name)
    (DateTime.now - t).should be_within(0.0001).of(0)
  end
    
  it "should enumerate all of the names of the objects stored" do

    data  = "Now is the time for all good men to come to the aid of their country!\n"

    name1 = "George Washington!"
    name2 = "Franklin/Delano/Roosevelt"
    name3 = "Yo' Mama sez!"

    @silo.put name1, data
    @silo.put name2, data
    @silo.put name3, data

    bag = []

    @silo.each do |name|
      bag.push name
    end

    bag.should have(3).things  
    bag.should include(name1)
    bag.should include(name2)
    bag.should include(name3)
  end  			

  it "should not allow invalid characters in the name" do

    data  = "Now is the time for all good men to come to the aid of their country!\n"
    name  = "George Washington!?"

    expect{ @silo.put(name, data)}.to raise_error(Store::SiloBadName)
  end  			

  it "should allow grep of all the names in the collection" do

    data = "This Is A Test. It Is Only A TEST."

    @silo.put "this", data
    @silo.put "that", data
    @silo.put "that other one over there", data

    results = @silo.grep(/that/)

    results.should have(2).things
    results.should include("that")
    results.should include("that other one over there")

  end

  it "should accept a block for geting data out in chunks" do

    name = some_name

    data_in = ''
    (1..1000).each { data_in += some_data }  # currently we read in 4096 byte chunks, this should exceed that

    @silo.put(name, data_in)

    data_out = ''
    @silo.get(name) do |buff| 
      data_out = data_out + buff
    end

    data_in.should == data_out
  end

  it "should accept puting data from a file object" do

    input_data = some_data
    name = some_name

    tf = Tempfile.new("dang")
    tf.puts(input_data);
    tf.close

    file = File.open(tf.path)

    @silo.put(name, file)

    retrieved_data = @silo.get(name)
    retrieved_data.should == input_data

  end


  it "should get the md5 and sha1 checksums correct" do
    data = "This is a test.\n"
    md5  = "02bcabffffd16fe0fc250f08cad95e0c"
    sha1 = "0828324174b10cc867b7255a84a8155cf89e1b8b"
    name = some_name
    
    @silo.put(name, data)    
    @silo.md5(name).should  == md5
    @silo.sha1(name).should == sha1
  end
  
  it "should get the md5 checksum correct when reading from a data file handle" do
    data = "This is a test.\n"
    md5  = "02bcabffffd16fe0fc250f08cad95e0c"
    name = some_name
    
    tf = Tempfile.new("heck")
    tf.puts(data)
    tf.close
    
    @silo.put(name, File.open(tf.path))
    @silo.md5(name).should == md5
  end

  it "should delete an object given an object name" do
    name = "test object"
    data = "some data!"
    @silo.put name, data
    @silo.delete name
    @silo.get(name).should be_nil
  end

  it "should indicate saved storage exists" do
    name = some_name
    data = some_data

    @silo.exists?(name).should == false
    @silo.put(name, data)
    @silo.exists?(name).should == true
  end


# silo copy tests:

 it "should allow a copy of data from one silo to another" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @in_silo.copy_to_silo(name, @out_silo)

  @in_silo.get(name).should == data
  @out_silo.get(name).should == data
 end

 it "should throw specific exceptions on a copy of data from one silo to another, where the destination data already exists" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @out_silo.put name, data

  expect{ @in_silo.copy_to_silo(name, @out_silo) }.to raise_error(Store::SiloResourceExists)
 end

 it "should throw exception on a copy of data from one silo to another, where the source data does not exist" do
  name = some_name
  data = some_data

  expect{ @in_silo.copy_to_silo(name, @out_silo) }.to raise_error(Store::SiloError)
 end

# Internally, move_to_silo decides on which of two implementations to use. If the two silos are one
# the same disk partition, it uses the rename command, otherwise does a slower copy and delete.
#
#
# All move_to_silo_with_rename tests should be repeated below under move_to_silo_with_copy tests

 it "should allow a move from one silo to another" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @in_silo.get(name).should == data

  @in_silo.move_to_silo_with_rename(name, @out_silo)
  @in_silo.get(name).should == nil
  @out_silo.get(name).should == data
 end

 it "should throw specific exceptions for a silo move of data that already exists in the desitnation silo" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @out_silo.put name, data

  expect{ @in_silo.move_to_silo_with_rename(name, @out_silo) }.to raise_error(Store::SiloResourceExists)
 end

 it "should throw specific exceptions for a silo move of data that doesn't exist in the source silo" do
  name = some_name

  expect{ @in_silo.move_to_silo_with_rename(name, @out_silo) }.to raise_error(Store::SiloError)
 end


 it "should not remove source data on a failure to move that data to the desitnation silo" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @out_silo.put name, data

  expect{ @in_silo.move_to_silo_with_rename(name, @out_silo) }.to raise_error(Store::SiloResourceExists)
  @in_silo.get(name).should == data
 end

 # move_to_silo_with_copy tests should be exact copies of the above

 it "should allow a move from one silo to another" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @in_silo.get(name).should == data

  @in_silo.move_to_silo_with_copy(name, @out_silo)
  @in_silo.get(name).should == nil
  @out_silo.get(name).should == data
 end

 it "should throw specific exceptions for a silo move of data that already exists in the desitnation silo" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @out_silo.put name, data

  expect{ @in_silo.move_to_silo_with_copy(name, @out_silo) }.to raise_error(Store::SiloResourceExists)
 end

 it "should throw specific exceptions for a silo move of data that doesn't exist in the source silo" do
  name = some_name

  expect{ @in_silo.move_to_silo_with_copy(name, @out_silo) }.to raise_error(Store::StorageError)
 end


 it "should not remove source data on a failure to move that data to the desitnation silo" do
  name = some_name
  data = some_data

  @in_silo.put name, data
  @out_silo.put name, data

  expect{ @in_silo.move_to_silo_with_copy(name, @out_silo) }.to raise_error(Store::SiloResourceExists)
  @in_silo.get(name).should == data
 end





end
