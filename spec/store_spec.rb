require 'store'

# store.rb *should* just include the actual library files, but there
# is a version class method in it; we test those here.

describe Store do

  it "should provide a NAME constant" do
    (Store::NAME =~ /Silo-Pool Service/).should_not == nil
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

  it "should provide version uri information" do
    (Store.version.uri =~ %r{^info:fcla/daitss/silo}).should == 0
  end
  

end
