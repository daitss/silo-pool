$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), 'lib'))  # for spec_helpers

require 'store/silodb'
require 'store/poolreservation'
require 'store/db'
require 'fileutils'
require 'tempfile'
require 'find'
require 'yaml'
require 'digest/md5'
require 'digest/sha1'
require 'spec_helpers'

# TODO: nimby for non-rf hosts, or where we don't have 3 silos of size 15MB

include Store

describe "pool reservation" do

  def silos
    @silos
  end

  def hostname
    @hostname
  end

  before(:all) do
    DB.setup(File.join(File.dirname(__FILE__), 'db.yml'), 'silos_mysql')
    DB::DM.automigrate!

    @roots    = Dir["/Volumes/silo-0*"]
    @hostname = 'example.com'    
    @silos    = []

    @roots.each do |path| 
      Find.find(path) do |filename|
        next if @roots.include? filename
        next if filename =~ %r{/.Trashes}
        next if filename =~ %r{/.fseventsd}
        File.chmod(0777, filename)
      end
      FileUtils::rm_rf Dir["#{path}/*"]
      @silos.push SiloDB.create(@hostname, path)
    end
  end

  after(:all) do
  end


  # TODO: we have 3 15MB silos - need to check & exit if they are not available


  it "should fill up the first 15MB silo as much as possible, leaving other silos alone" do

    data = "x" * 4_712_000  # should fill up the first of the empty silos after 3 PUTs.

    @@selected_silo = nil

    PoolReservation.new(data.length) do |silo|
      @@selected_silo = silo
      silo.put(some_name(), data)
    end

    PoolReservation.new(data.length) do |silo|
      silo.put(some_name(), data)
      silo.filesystem.should == @@selected_silo.filesystem
    end

    PoolReservation.new(data.length) do |silo|
      silo.put(some_name(), data)
      silo.filesystem.should == @@selected_silo.filesystem
    end
  end


  it "should fill up the next silo when the first is full" do

    data = "x" * 8_000_000

    PoolReservation.new(data.length) do |silo|
      silo.put(some_name(), data)
      silo.filesystem.should_not == @@selected_silo.filesystem
      @@selected_silo = silo
    end

    PoolReservation.new(data.length) do |silo|
      silo.put(some_name(), data)
      silo.filesystem.should_not == @@selected_silo.filesystem
    end

  end

  it "should raise an error when there's no room to store a package" do
    data = "x" * 8_000_000
    lambda { PoolReservation.new(data.length) { |silo|  silo.put(some_name(), data) }  }.should raise_error
  end

end
