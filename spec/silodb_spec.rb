$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), 'lib'))  # for spec_helpers

require 'store/silodb'
require 'store/db'
require 'fileutils'
require 'tempfile'
require 'find'
require 'yaml'
require 'digest/md5'
require 'digest/sha1'
require 'spec_helpers'

include Store

describe SiloDB do

  before(:all) do
    DB.setup(File.join(File.dirname(__FILE__), 'db.yml'), 'silos_mysql')
    DB::DM.automigrate!

    @silo_root = File.join(File.dirname(__FILE__), 'tests', 'silos', '001')
    FileUtils::mkdir_p @silo_root
    @hostname = 'example.com'    
  end

  after(:all) do
    Find.find(@silo_root) do |filename|
      File.chmod(0777, filename)
    end
    FileUtils::rm_rf @silo_root
  end

  it "should allow us to create a new silo from an existing directory" do
    lambda { SiloDB.create @hostname, @silo_root }.should_not raise_error
  end

  it "should instantiate a silo record based on an existing directory" do
    lambda { SiloDB.new @hostname, @silo_root}.should_not raise_error
  end

  it "should include useful information in it's print name" do
    str = "#{SiloDB.new @hostname, @silo_root}"

    (str =~ /#{@hostname}/).should_not  == nil
    (str =~ /#{@silo_root}/).should_not == nil
  end

  it "should provide a list of silo records based on hostname" do
    new_hostname = 'another.' + @hostname

    SiloDB.create new_hostname, @silo_root
    list = SiloDB.silos new_hostname
    
    list.length.should == 1
  end

  it "should provide a list of hosts for which we have silos" do
    list = SiloDB.hosts
    
    list.length.should > 1
    list.include?(@hostname).should == true
  end

  it "should not instantiate a silo record based on an non-existing directory" do
    root = File.join(File.dirname(__FILE__), 'tests', 'silos', '002')
    File.directory?(root).should_not == true
    lambda { SiloDB.new @hostname, root }.should raise_error
  end

  it "should allow us to PUT a package, GETting it later" do

    silo1 = SiloDB.new @hostname, @silo_root
    data = some_data
    name = some_name
    lambda { silo1.put name, data }.should_not raise_error

    silo2 = SiloDB.new @hostname, @silo_root
    silo2.get(name).should == data
  end

  it "should iterate over existing packages, allowing us to retrieve its data" do
    data = some_data
    name = some_name

    silo = SiloDB.new @hostname, @silo_root

    silo.put(name, data)
    found = false
    silo.each do |n|
      found ||= (name == n)
    end
    found.should == true
    silo.get(name).should == data
  end

  
  it "should allow us to DELETE a package after which it won't be found on a silo iteration" do
    data = some_data
    name = some_name

    silo = SiloDB.new @hostname, @silo_root

    silo.put(name, data)
    silo.delete(name)

    found = false
    silo.each do |n|
      found ||= (name == n)      
    end

    found.should == false
  end

  it "should provide fixity data for a package, immediately on a PUT" do
    data = some_data
    name = some_name

    silo = SiloDB.new @hostname, @silo_root
    silo.put(name, data)

    records = silo.fixity_report(name).fixity_records

    records.length.should == 1
    rec = records[0]
    rec[:action].should == :put
    rec[:md5].should    == Digest::MD5.hexdigest(data)
    rec[:sha1].should   == Digest::SHA1.hexdigest(data)    
  end

  
  it "should allow us to perform a fixity check on a package, " do
    data = some_data
    name = some_name
    md5  = Digest::MD5.hexdigest(data)
    sha1 = Digest::SHA1.hexdigest(data)    

    silo = SiloDB.new @hostname, @silo_root
    silo.put(name, data)
    silo.fixity(name, :md5 => md5, :sha1 => sha1)

    records = silo.fixity_report(name).fixity_records

    records.length.should == 2
    rec = records[1]
    rec[:action].should == :fixity
    rec[:md5].should    == md5
    rec[:sha1].should   == sha1
  end


  it "should no longer provide fixity records when the package has been deleted" do
    data = some_data
    name = some_name
    md5  = Digest::MD5.hexdigest(data)
    sha1 = Digest::SHA1.hexdigest(data)    

    silo = SiloDB.new @hostname, @silo_root
    silo.put(name, data)
    silo.fixity(name, :md5 => md5, :sha1 => sha1)
    silo.delete(name)

    report = silo.fixity_report(name)
    report.should_not == nil
    records = report.fixity_records
    records.length.should == 0
  end



  it "should allow us to get a fixity report for all packages on the system" do
    silo  = SiloDB.new @hostname, @silo_root
    count = 0
    some_name = nil

    silo.each { |name| count += 1; some_name = name }

    report = silo.fixity_report

    report.fixity_check_count.should == count

    found = false
    report.fixity_records.each { |rec| found ||=  rec[:name] == some_name }
    found.should == true   
  end
end
