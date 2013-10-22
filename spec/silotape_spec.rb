$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), 'lib'))        # for spec_helpers

require 'store/silotape'
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

describe SiloTape do

  TAPE_SERVER = 'ADSM_TEST'

  before(:all) do
    
    DB.setup(File.join(File.dirname(__FILE__), 'db.yml'), 'silos_mysql')
    DB::DM.automigrate!
    
    # create a new silo and add some data to it with SiloDB; SiloDB initializes
    # the DB, just as it would do in real life...

    @silo_root  = File.join(File.dirname(__FILE__), 'tests', 'daitssfs', '001')

    if File.exists? @silo_root
      FileUtils::chmod_R 0755, @silo_root
      FileUtils::rm_rf @silo_root
    end

    FileUtils::mkdir_p @silo_root

    @hostname = 'localhost'
    
    SiloDB.create @hostname, @silo_root
    
    silo_db = SiloDB.new @hostname, @silo_root

    [1..10].each { |i| silo_db.put some_name, some_data }

    @name = 'E20010101_AAAAAG'

    silo_db.put @name, some_data

    # clean out the silo directory for the cache silo, recreating it.

    @cache_root = File.join(File.dirname(__FILE__), 'tests', 'daitssfs-cache')    
    
    if File.exists? @cache_root
      FileUtils::chmod_R 0755, @cache_root
      FileUtils::rm_rf @cache_root
    end

    FileUtils::mkdir_p @cache_root

    Store.class_variable_set(:@@silo,nil)  
  end

  after(:all) do
  end

  it "should instantiate a silo record based on an existing directory" do
    lambda { SiloTape.new @hostname, @silo_root, @cache_root, TAPE_SERVER }.should_not raise_error
  end

  it "should include useful information in it's print name" do
    silo = SiloTape.new @hostname, @silo_root, @cache_root, TAPE_SERVER
    str  = silo.to_s

    (str =~ /#{@hostname}/).should_not  == nil
    (str =~ /#{@silo_root}/).should_not == nil
  end

  it "should not allow PUTs" do
    #@@silo = SiloTape.new @hostname, @silo_root, @cache_root, TAPE_SERVER 
    silotape = SiloTape.new @hostname, @silo_root, @cache_root, TAPE_SERVER 
    Store.class_variable_set(:@@silo, silotape) 
    lambda { Store.class_variable_get(:@@silo).put "somename", "somedata" }.should raise_error
  end

  it "should get the original datetime from the silo for E20010101_AAAAAG, which was placed by SiloDB" do
    (DateTime.now - Store.class_variable_get(:@@silo).datetime('E20010101_AAAAAG') < 1).should == true
  end

end
