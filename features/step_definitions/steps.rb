$LOAD_PATH.unshift  File.dirname(__FILE__)

require 'helpers'

Before  do
  @@active_silo = 'http://storage.local/a/data/'
end

After do
  @@new_package.delete
end

Given /^a silo$/ do
end

Given /^a new package$/ do
  @@new_package = Package.new
end

When /^I send the package$/ do
  @response = Client.new(@@active_silo).put @@new_package
end

Then /^I should see "([^\"]*)"$/ do |arg1|
  code, message = arg1.split(/\s+/, 2)
  @response.code.should    == code 
  @response.message.should =~ /#{message}/
end

# Given /^a silo and a previously stored package$/ do
# end

# Given /^a silo and a previously deleted package$/ do
#   @@active_silo.should_not == nil
#   @@new_package.should_not == nil
# end

When /^I retrieve the package$/ do
  @response = Client.new(@@active_silo).get @@new_package
end

When /^I delete the package$/ do
  @response = Client.new(@@active_silo).delete @@new_package
end

# Then /^I should get it$/ do
#   @response = Client.new(@@active_silo).get @@new_package  
# end

Then /^the checksum of the retrieved package should match the package$/ do
  @@new_package.md5.should == Digest::MD5.hexdigest(@response.body)
end


