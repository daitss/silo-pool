# -*- mode: ruby; -*- 

require 'bundler/setup'
require 'digest/md5'

$LOAD_PATH.unshift File.expand_path(File.join(File.dirname(__FILE__), 'lib'))

# We normally want to set the following in an Apache config file or a startup script.
# These are development defaults.

ENV['LOG_FACILITY']         ||= nil                   # Logger sets up syslog using the facility code if set, stderr otherwise.

ENV['DATABASE_CONFIG_FILE'] ||= '/opt/fda/etc/db.yml' # YAML file that only our group can read, has database information in it.
ENV['DATABASE_CONFIG_KEY']  ||= 'silos'               # Key into a hash provided by the above file.

ENV['TIVOLI_SERVER']        ||= 'ADSM_TEST'           # The TSM server we query against for tape backups of the silo directories.
ENV['SILO_TEMP']            ||= '/tmp'                # Filesystems restored from tape land in mini-silos here.

ENV['BASIC_AUTH_USERNAME']  ||= nil                   # Requirements to connect to the silo system
ENV['BASIC_AUTH_PASSWORD']  ||= nil                   # using basic authentication; nil USERNAME means no authentication

if ENV['BASIC_AUTH_USERNAME']
  use Rack::Auth::Basic, "DAITSS 2.0 Silo" do |username, password|
    username == ENV['BASIC_AUTH_USERNAME']  &&  password == ENV['BASIC_AUTH_PASSWORD']
  end
end

require 'sinatra'
require 'app'

run Sinatra::Application
