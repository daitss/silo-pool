require 'store'

# store.rb *should* just include the actual library files, but there
# is a version class method in it; we test those here.

describe Store do

  it "should provide a NAME constant" do
    (Store::NAME =~ /Storage/).should_not == nil
  end

  it "should provide a VERSION constant" do
    (Store::VERSION =~ /\d+\.\d+\.\d+/).should == 0
  end

  it "should provide a RELEASE constant" do
    (Store::RELEASE.length > 0).should == true
  end

  it "should provide a REVISION constant" do
    (Store::REVISION.length > 0).should == true
  end

  it "should provide a to_s method on version that matches the version label information" do
    ("#{Store.version}" =~ /^Silo Storage/).should == 0
  end

  it "should provide version rev information" do
    (Store.version.rev =~ %r{Version}).should_not == nil
  end

  it "should provide version uri information" do
    (Store.version.uri =~ %r{^info:fcla/daitss/silos}).should == 0
  end
  

end
