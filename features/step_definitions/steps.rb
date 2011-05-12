$LOAD_PATH.unshift  File.dirname(__FILE__)

require 'helpers'


# You have to set up these to point to an active silo

Before  do
  @@active_pool = "http://pool.a.local"
  @@active_silo = "#{@@active_pool}/silo-pool.a.1/data/"
  @@service_url = "#{@@active_pool}/services"
end

After do
  @@new_package.delete
end

Given /^a silo$/ do
end

Given /^a pool$/ do
end

Given /^a new package$/ do
  @@new_package = Package.new
end

When /^I PUT the package$/ do
  @response = Client.new(@@active_silo).put @@new_package
end


Then /^I should see "([^\"]*)"$/ do |arg1|
  code, message = arg1.split(/\s+/, 2)
  @response.code.should    == code 
  @response.message.should =~ /#{message}/
end


When /^I GET the package$/ do
  @response = Client.new(@@active_silo).get @@new_package
end

When /^I DELETE the package$/ do
  @response = Client.new(@@active_silo).delete @@new_package
end

Then /^the checksum of the retrieved package should match the package$/ do
  @@new_package.md5.should == Digest::MD5.hexdigest(@response.body)
end


# Support for newer protocol

When /^I GET the service document$/ do
  @response = Client.new(@@service_url).get
end

Then /^I should receive a create URL in the response$/ do
  @response.body.should =~ /create/
end
