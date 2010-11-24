require 'store/tsmexecutor'
require 'store/silo'
require 'store/utils'
require 'fileutils'
require 'tempfile'
require 'find'

describe Store::TsmExecutor do

  def read_dir dir, absolute = true
    dir = dir.gsub(%{/+$}, '') + '/'
    files = []
    Find.find(dir) do |f|
      unless File.directory? f
        files.push  absolute ?  f : f.gsub(/^#{dir}/, '')
      end
    end
    files.sort
  end

  def fstat_method dir, method
    read_dir(dir).map { |f| File.stat(f).send(method) }
  end

  def mtimes dir;    fstat_method dir, :mtime;  end
  def sizes  dir;    fstat_method dir, :size;   end
  def modes  dir;    fstat_method dir, :mode;   end
  def ctimes dir;    fstat_method dir, :ctime;  end

  def checksums dir
    md5s = []
    read_dir(dir).each { |f| md5s.push Digest::MD5.hexdigest(File.read(f)) }
    md5s
  end
   
  def tsm_directory dir
    prefix = StoreUtils.disk_mount_point dir
    if prefix == '/'
      return dir.gsub %r{^/}, '{/}'
    else
      ### TODO: implement and test the longer prefix
      return dir
    end
  end
  
  def dump_listing listing
    count = 0
    listing.each { |rec| STDERR.puts "#{sprintf("%4d", count += 1)} #{rec[:time]}\t#{rec[:size]}\t#{rec[:path]}" }
  end

  def underline str
    "\n" + str + "\n" + str.gsub(/./, ':') + "\n"
  end

  def report tsm
    STDERR.puts underline(tsm.command + " - exited #{tsm.status}")
    STDERR.puts underline('output')
    tsm.output { |line| STDERR.puts "      " + line }
    STDERR.puts underline('errors')
    tsm.errors { |line| STDERR.puts "      " + line }
    STDERR.puts "\n"
  end

  def new_ieid
    (@base.succ!).clone
  end

  def servername
    'ADSM_TEST'
  end

  def some_data
    data = "Some test data: #{rand(100000000)}\n"
  end

  @@tsm = nil
    
  def setup_silo
    @root_dir = File.expand_path(File.join(File.dirname(__FILE__), 'tests', 'tsm', rand(100000).to_s)) # .../spec/tests/tsm/63206/
    @silo_dir = FileUtils.mkdir_p(File.join(@root_dir, 'silo-000'))+ File::SEPARATOR                   # .../spec/tests/tsm/63206/silo-000
    @copy_dir = FileUtils.mkdir_p(File.join(@root_dir, 'restore-directory')) + File::SEPARATOR         # .../spec/tests/tsm/63206/restore-directory

    @silo = Store::Silo.new(@silo_dir)
    @silo.put(new_ieid, some_data)
    @silo.put(new_ieid, some_data)
    @silo.put(new_ieid, some_data)
  end

  def restores_dir
    # e.g. say                             @silo_dir = .../spec/tests/63206/silo-001/
    # then, after restore we should have   @copy_dir = .../spec/tests/63206/restore-directory/silo-001/

    File.join(@copy_dir, File.basename(@silo_dir)) + File::SEPARATOR
  end

  def nimby
    pending("Can't run this test here") unless `hostname` =~ /retsina.fcla.edu/i
  end

  before(:all) do
    @base = Time.now.strftime("%Y%m%d_AAAAAA")
    setup_silo
  end

  after(:all) do
    Find.find(@root_dir) do |filename|
      File.chmod(0777, filename)
    end
    FileUtils::rm_rf @root_dir
  end

  it "should let us create an object, and get the server and default timeouts" do
    nimby
    tsm = Store::TsmExecutor.new 'BIG-BAD-SERVER'
    tsm.server.should  == 'BIG-BAD-SERVER'
    tsm.timeout.should == 3600
  end

  it "should let us create an object, and get the server and specified timeouts" do
    nimby
    tsm = Store::TsmExecutor.new 'BIG-BAD-SERVER', 600
    tsm.server.should  == 'BIG-BAD-SERVER'
    tsm.timeout.should == 600
  end

  it "should allow us to save material to tape, giving us a tsm-style directory specification (braces around the mount point)" do
    nimby
    @@tsm = Store::TsmExecutor.new servername, 120
    path = @@tsm.save(@silo_dir)

    @@tsm.status.should == 0
    (path =~ /\{.*\}/).should == 0
    (path.gsub('{', '').gsub('}', '')).should == @silo_dir
  end

  it "should allow us to list saved materials from tape" do
    nimby
    listing = @@tsm.list(tsm_directory(@silo_dir))
    @@tsm.status.should == 0
    listing.length.should > 0
  end

  it "should allow us to restore saved materials from tape" do
    nimby
    @@tsm.restore(tsm_directory(@silo_dir), @copy_dir)
    @@tsm.status.should == 0
  end

  it "should have a copy of all of our restored material" do
    nimby
    read_dir(@silo_dir, false).should == read_dir(restores_dir, false)
  end

  it "should preserve modes on restores" do
    nimby
    modes(@silo_dir).should == modes(restores_dir)
  end

  it "should preserve modification times on restores" do
    nimby
    mtimes(@silo_dir).should == mtimes(restores_dir)
  end

  it "should preserve contents on restores" do
    nimby
    checksums(@silo_dir).should == checksums(restores_dir)
  end

  it "should allow us to delete a single file" do
    pending "Tivoli deletes are no longer supported by silo code."
    nimby

    # find something to delete

    list1 = @@tsm.list(tsm_directory(@silo_dir))
    list1.length.should > 0

    to_delete = nil
    list1.each { |rec|  to_delete = rec[:path] if rec[:path] =~ /data/ }
    to_delete.should_not == nil

    # delete it:
    
    @@tsm.delete(to_delete)
    @@tsm.status.should == 0

    # look for it, and don't find it:

    list2 = @@tsm.list(tsm_directory(@silo_dir))
    (list2.inject(false) { |found, rec| found || (rec[:path] == to_delete) }).should == false
    list1.length.should == list2.length + 1
  end

  it "should allow us to delete a set of directories from tape" do
    pending "Tivoli deletes are no longer supported by silo code."
    nimby
    @@tsm.delete(tsm_directory(@silo_dir))
    @@tsm.status.should == 0
  end

  it "should now not list any saved materials on tape" do
    pending "Tivoli deletes are no longer supported by silo code."
    nimby
    list = @@tsm.list(tsm_directory(@silo_dir))
    @@tsm.status.should == 0
    list.length.should  == 0
  end

end
