$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), 'lib'))        # for spec_helpers

require 'dm-core'

require 'digest/md5'
require 'digest/sha1'
require 'fileutils'
require 'socket'
require 'store/db'
require 'store/exceptions'
require 'yaml'
require 'spec_helpers'


include Store

HOME = File.dirname(__FILE__)

DM_POSTGRES_LOG = File.join(HOME, 'dm-postgres.log')

FileUtils.rm_f DM_POSTGRES_LOG

def postgres_setup
  DataMapper::Logger.new(DM_POSTGRES_LOG, :debug)
  DB.setup(File.join(HOME, 'db.yml'), 'silos_postgres')
  DB::DM.automigrate!
end


#### .should 

share_examples_for "DataMapper ReservedDiskSpace class using any database" do

  it "should alow us to create a record" do
    rec = DB::ReservedDiskSpace.create(:partition => '/', :size => rand(1000))
    rec.saved?.should == true
  end

  it "should alow us to destroy a record based on the id" do
    rec1 = DB::ReservedDiskSpace.create(:partition => '/', :size => rand(1000))
    rec1.saved?.should == true

    rec2 = DB::ReservedDiskSpace.get(rec1['id'])
    rec2.destroy.should == true
  end


  it "should allow us to create a reservation with explicit datetime" do
    date = DateTime.now
    rec1 = DB::ReservedDiskSpace.create(:partition => '/', :size => rand(1000), :timestamp => date)
    rec2 = DB::ReservedDiskSpace.get(rec1['id'])    
    (date - rec2.timestamp).should  be_within(0.0001).of(0)
  end
  
  it "should allow us to clean out stale records" do
    DB::ReservedDiskSpace.all.destroy
    
    datetime = DateTime.now - 1

    DB::ReservedDiskSpace.create(:partition => '/', :size => rand(1000), :timestamp => datetime)
    DB::ReservedDiskSpace.create(:partition => '/', :size => rand(1000), :timestamp => datetime)
    DB::ReservedDiskSpace.create(:partition => '/', :size => rand(1000)) # defaults to now

    DB::ReservedDiskSpace.all.length.should == 3
    DB::ReservedDiskSpace.cleanout_stale_reservations 0.5
    DB::ReservedDiskSpace.all.length.should == 1
  end


  it "should all us to find a list of unique partitions" do

    DB::ReservedDiskSpace.all.destroy

    ['/a', '/b', '/c'].each do |partition|
      DB::ReservedDiskSpace.create(:partition => partition, :size => rand(1000))
      DB::ReservedDiskSpace.create(:partition => partition, :size => rand(1000))
    end
    
    partitions = DB::ReservedDiskSpace.distinct_partitions

    partitions.length.should == 3

    partitions.include?('/a').should == true
    partitions.include?('/b').should == true
    partitions.include?('/c').should == true
  end


  it "should give us a hash of partition reservations" do

    too_old = 100
    
    DB::ReservedDiskSpace.all.destroy

    DB::ReservedDiskSpace.create(:partition => '/a', :size => 1)
    DB::ReservedDiskSpace.create(:partition => '/a', :size => 1)
    DB::ReservedDiskSpace.create(:partition => '/a', :size => 1)
    DB::ReservedDiskSpace.create(:partition => '/a', :size => 1)

    DB::ReservedDiskSpace.create(:partition => '/b', :size => 1)
    DB::ReservedDiskSpace.create(:partition => '/b', :size => 1)
    DB::ReservedDiskSpace.create(:partition => '/b', :size => 1)

    DB::ReservedDiskSpace.create(:partition => '/c', :size => 1)
    DB::ReservedDiskSpace.create(:partition => '/c', :size => 1)

    DB::ReservedDiskSpace.create(:partition => '/d', :size => 1)

    recs = DB::ReservedDiskSpace.partition_reservations(too_old)

    recs.keys.length == 4

    recs['/a'].should == 4
    recs['/b'].should == 3
    recs['/c'].should == 2
    recs['/d'].should == 1
  end

end  # of DataMapper ReservedDiskSpace class using any database



describe "DataMapper ReservedDiskSpace class using Postgres" do
  before(:all) do
    postgres_setup
  end
  it_should_behave_like "DataMapper ReservedDiskSpace class using any database"
end



share_examples_for "DataMapper SiloRecord class using any database" do

  it "should return an empty list when there are no silos" do
    DB::SiloRecord.list.should == []
  end

  it "should allow us to lookup a non-existing silo record without error" do
    rec = DB::SiloRecord.lookup 'example.com', @silo_root
    rec.should == nil
  end

  it "should allow us to create a silo based on a fictituous hostname" do
    rec = DB::SiloRecord.create 'example.com', @silo_root
    rec.should_not == nil
    rec.hostname.should == 'example.com'
  end

  it "should not allow us to create a second silo with the same parameters" do
    lambda { DB::SiloRecord.create 'example.com', @silo_root }.should raise_error
  end

  it "should return the correct sized-list of silos for a given hostname" do
    rec = DB::SiloRecord.create 'example.com', @silo_root_1
    DB::SiloRecord.list('example.com').length.should == 2
  end

  it "should return the correct sized-list of silos for a given hostname regardless of case" do
    rec = DB::SiloRecord.create  'EXAMPLE.com', @silo_root_2
    DB::SiloRecord.list('example.COM').length.should == 3
  end

  it "should default to :disk_master state of silo on initial creation" do
    rec = DB::SiloRecord.lookup 'example.com', @silo_root
    rec.state.should == :disk_master
  end

  it "should provide default allowed HTTP methods of :get" do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root

    rec.allowed_methods.length.should            == 1
    rec.allowed_methods.include?(:get).should    == true
    rec.allowed_methods.include?(:put).should    == false
    rec.allowed_methods.include?(:delete).should == false
  end

  it "should return a media_device of :disk in the default state" do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state.should == :disk_master
    rec.media_device.should == :disk
  end


  it "should allow us to to change the state of a silo to idling" do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state = :disk_idling
    rec.save
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state.should == :disk_idling
  end


  it "should return a media_device of :disk in the idling state" do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state.should == :disk_idling
    rec.media_device.should == :disk
  end


  it "should provide only :get HTTP methods when in the idling state" do

    rec = DB::SiloRecord.lookup  'example.com', @silo_root

    rec.state.should                             == :disk_idling
    rec.allowed_methods.length.should            == 1
    rec.allowed_methods.include?(:get).should    == true
  end


  it "should be able to change state from :disk_idling to  :tape  " do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state = :tape_master
    rec.save
  end
=begin
  it "should provide only :get and :delete HTTP methods when moved from the idling to tape master state" do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state = :tape_master
    rec.save

    rec = DB::SiloRecord.lookup  'example.com', @silo_root

    rec.allowed_methods.length.should            == 2
    rec.allowed_methods.include?(:get).should    == true
    rec.allowed_methods.include?(:delete).should == true
    rec.allowed_methods.include?(:put).should    == false
  end
=end


  it "should provide only :get and :delete HTTP methods when moved from the idling to tape master state" do
# changed on the db but the lookup does not work
    rec = DB::SiloRecord.lookup  'example.com', @silo_root

    rec.allowed_methods.length.should            == 1
    rec.allowed_methods.include?(:get).should    == true
    rec.allowed_methods.include?(:delete).should == false
    rec.allowed_methods.include?(:put).should    == false
  end

  it "should return a media_device of :tape in the tape master state" do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state.should == :tape_master
    rec.media_device.should == :tape
  end

  it "should allow us to associate one filesystem with two hosts" do
    rec = DB::SiloRecord.create('another.example.com', @silo_root)
    rec.saved?.should == true
  end

  it "should not allow us to use the same filesystem with one host" do  # requires previous test
    lambda { DB::SiloRecord.create('another.example.com', @silo_root) }.should raise_error
  end

  it "should allow us to get a list of just the silos for a particular hostname" do

    new_hostname = 'first-time-used.com'
    rec  = DB::SiloRecord.create new_hostname, @silo_root_3

    list_one  = DB::SiloRecord.list new_hostname
    list_all  = DB::SiloRecord.list
    list_some = DB::SiloRecord.list 'example.com'

    list_one.length.should == 1
    (list_all.length > list_some.length).should == true

    list_all.include?(rec).should == true
    list_one.include?(rec).should == true
    list_some.include?(rec).should == false
  end

  it "should allow us to forbid, then allow, a GET method when a silo is in the tape_master state"  do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state.should == :tape_master
    (rec.allowed_methods.include? :get).should == true
    rec.forbid :get
    (rec.allowed_methods.include? :get).should == false
    rec.allow :get
    (rec.allowed_methods.include? :get).should == true
  end


  it "should raise an error if we try to allow PUT method when a silo is in the tape_master state"  do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state.should == :tape_master
    (rec.allowed_methods.include? :put).should == false
    lambda { rec.allow :put }.should raise_error ConfigurationError
  end


  it "should allow a PUT method when a silo is in the disk_master state"  do
    rec = DB::SiloRecord.lookup  'example.com', @silo_root
    rec.state = :disk_master
    rec.save!

    (rec.allowed_methods.include? :put).should == false
    rec.allow  :put
    (rec.allowed_methods.include? :put).should == true
    lambda { rec.allow :put }.should_not raise_error ConfigurationError
  end

end # of share_examples_for "DataMapper SiloRecord class using any database"





describe "DataMapper SiloRecord class using Postgres" do
  before(:all) do
    postgres_setup

    # @silo_root = File.expand_path(File.join(File.dirname(__FILE__), 'tests', 'db', rand(100000).to_s))  # .../spec/tests/db/63206
    @silo_root   = File.expand_path("/tmp/silos/000")
    @silo_root_1 = File.expand_path("/tmp/silos/001")
    @silo_root_2 = File.expand_path("/tmp/silos/002")
    @silo_root_3 = File.expand_path("/tmp/silos/003")
  end

  it_should_behave_like "DataMapper SiloRecord class using any database"
end



share_examples_for "DataMapper PackageRecord class using any database" do

  # We have a broken-by-design issue here.  We can have a package with no
  # history entries,  which should not be allowed.

  it "should provide an empty list of packages for a given silo, initially" do
    DB::PackageRecord.list(@silo_rec).should == []
  end

  it "should allow us to lookup a non-exisiting package error without error, returning nil" do
    rec = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED")
    rec.should == nil
  end

  it "should allow us to create a package based on a silo record and name" do
    opts = some_attributes
    rec = DB::PackageRecord.create(@silo_rec, "E20100326_DEADED", some_attributes )
    rec.should_not == nil
  end

  it "should have an informative print name" do
    str = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED").to_s

    (str =~ /#{@silo_rec.filesystem}/).should_not == nil
    (str =~ /#{@silo_rec.hostname}/).should_not == nil
    (str =~ /E20100326_DEADED/).should_not == nil
  end


  it "should not allow us to recreate an existing package" do
    lambda { DB::PackageRecord.create(@silo_rec, "E20100326_DEADED", some_attributes ) }.should raise_error
  end

  it "should create packages with a default :extant of true" do
    pkg = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED")
    pkg.extant.should == true
  end

  it "should allow us to change the :extant slot, and retain it" do
    pkg = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED")
    pkg.extant = false
    pkg.save

    pkg2 = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED")
    pkg2.extant.should == false
  end

  it "should allow us to retrieve the silo object" do
    pkg = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED")
    pkg.silo_record.should == @silo_rec
  end

  it "should allow us to get a list of all packages by silo" do
    pkg  = DB::PackageRecord.lookup(@silo_rec, "E20100326_DEADED")
    pkg  = DB::PackageRecord.create(@silo_rec, "E19561201_BIRTHD", some_attributes)
    list = DB::PackageRecord.list(@silo_rec)
    list.include?(pkg).should == true
    list.length.should == 2
  end

  it "should not allow us to create a second package record based on the silo and package name" do
    name = some_name
    pkg1   = DB::PackageRecord.create(@silo_rec, name, some_attributes)
    lambda { DB::PackageRecord.create(@silo_rec, name, some_attributes) }.should raise_error
    pkg2  =  DB::PackageRecord.lookup(@silo_rec, name)
    (pkg1['id'] == pkg2['id']).should == true
  end




  it "should allow us to raw list of package data for a given silo" do
    list = DB::PackageRecord.raw_list(@silo_rec)
    list.length.should == 3

    list = DB::PackageRecord.raw_list(@silo_rec, :extant => true)
    list.length.should == 2

    rec = list.pop

    [ :name, :extant, :id, :size, :type, :initial_sha1, :initial_md5, :initial_timestamp, :latest_sha1, :latest_md5, :latest_timestamp ].each do |meth|
      rec.respond_to?(meth).should == true
    end
    rec.latest_timestamp.class.should  == DateTime
    rec.initial_timestamp.class.should == DateTime
  end

end # of share_examples_for "DataMapper PackageRecord class using any database"



describe "DataMapper PackageRecord class using Postgres" do

  before(:all) do
    postgres_setup

    @silo_root = File.expand_path("/tmp/silos/001")
    @silo_rec  = DB::SiloRecord.create(my_host, @silo_root)
  end

  it_should_behave_like "DataMapper PackageRecord class using any database"
end



share_examples_for "DataMapper HistoryRecord class using any database" do

  it "should allow us get an empty list of histories, initially, for a silo_record and package name that's never been recorded" do
    DB::HistoryRecord.list(@silo_rec, @package_name_1).should == []
  end

  it "should create and return a package on the fly when doing a put" do
    hst1 = DB::HistoryRecord.put(@silo_rec, @package_name_1, some_attributes)
    pkg1 = DB::PackageRecord.lookup(@silo_rec, @package_name_1)

    (hst1.package_record == pkg1).should == true
  end

  it "should throw error when we've got wrong sized sha1 or md5" do
    lambda { DB::HistoryRecord.put(@silo_rec, some_name, some_attributes.merge(:md5  => '456')) }.should raise_error
    lambda { DB::HistoryRecord.put(@silo_rec, some_name, some_attributes.merge(:sha1 => '7890')) }.should raise_error
  end

  it "should throw error when we're missing a sha1 on recording a PUT" do
    lambda { DB::HistoryRecord.put(@silo_rec, some_name, some_attributes.minus(:sha1)) }.should raise_error
  end

  it "should throw error when we're missing a md5 on recording a PUT" do
    lambda { DB::HistoryRecord.put(@silo_rec, some_name, some_attributes.minus(:md5)) }.should raise_error
  end

  it "should throw error when we're missing a timestamp on recording a PUT" do
    lambda { DB::HistoryRecord.put(@silo_rec, some_name, some_attributes.minus(:timestamp)) }.should raise_error
  end

  it "should allow us to create a PUT on an existing package" do
    pkg1 = DB::PackageRecord.lookup(@silo_rec, @package_name_1)

    initial_sha1  = pkg1.sha1
    initial_md5   = pkg1.md5
    initial_time  = pkg1.datetime

    new_attributes = some_attributes

    hist  = DB::HistoryRecord.put(pkg1, new_attributes)

    pkg2  = DB::PackageRecord.lookup(@silo_rec, @package_name_1)

    pkg1.should == pkg2

    hist.action.should      == :put
    hist.sha1.should        == new_attributes[:sha1]
    hist.md5.should         == new_attributes[:md5]
    hist.timestamp.should   == new_attributes[:timestamp]

    hist.package_record.should == pkg2

    pkg2.sha1.should         == new_attributes[:sha1]
    pkg2.md5.should          == new_attributes[:md5]
    pkg2.datetime.should_not == initial_time
  end



  it "should reflect the number of saved historical records for a package, when specified by silo record and package name" do

    attr = some_attributes

    attr[:timestamp] = DateTime.now - 10
    DB::HistoryRecord.put(@silo_rec, @package_name_2, attr)                # first use this package in test suite

    attr[:timestamp] += 1
    DB::HistoryRecord.fixity(@silo_rec, @package_name_2, attr)

    attr[:timestamp] += 1
    DB::HistoryRecord.fixity(@silo_rec, @package_name_2, attr)

    attr[:timestamp] += 1
    DB::HistoryRecord.fixity(@silo_rec, @package_name_2, attr)

    DB::HistoryRecord.list(@silo_rec, @package_name_2).length.should == 4  # 1 put, 3 fixities
  end



  it "should reflect the number of saved historical records for a package, when specified by a pacakge_record" do

    package_rec = DB::PackageRecord.lookup(@silo_rec, @package_name_2)     # same package as above

    attr = some_attributes

    attr[:timestamp] = DateTime.now - 2
    DB::HistoryRecord.fixity(package_rec, attr)     # 5

    attr[:timestamp] += 1
    DB::HistoryRecord.fixity(package_rec, attr)     # 6

    DB::HistoryRecord.delete(package_rec)           # 7

    DB::HistoryRecord.list(package_rec).length.should == 7
  end

  it "should not allow us to create a new FIXITY event based on a non-existing package" do
    lambda { DB::HistoryRecord.fixity(@silo_rec, @package_name_3, some_options) }.should raise_error
  end

  it "should not allow us to create a new DELETE event based on a non-existing package" do
    lambda { DB::HistoryRecord.delete(@silo_rec, @package_name_3) }.should raise_error
  end

end # of share_examples_for "DataMapper HistoryRecord class using any database"



describe "DataMapper HistoryRecord class using Postgres" do

    before(:all) do
    postgres_setup
    @silo_rec       = DB::SiloRecord.create(my_host, File.expand_path("/tmp/silos/002"))
    @package_name_0 = some_name
    @package_name_1 = some_name
    @package_name_2 = some_name
    @package_name_3 = some_name
    end

  it_should_behave_like "DataMapper HistoryRecord class using any database"
end

