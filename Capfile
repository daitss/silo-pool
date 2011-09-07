# -*- mode:ruby; -*-

require 'rubygems'
require 'railsless-deploy'
require 'bundler/capistrano'
require 'socket'

set :scm,          "git"
set :repository,   "git://github.com/daitss/silo-pool.git"
set :branch,       "master"

set :use_sudo,     false
set :user,         "silo"
set :group,        "daitss" 

set :keep_releases, 4   # default is 5

set :bundle_flags,       "--deployment"   # --deployment is one of the defaults, we explicitly set it to remove --quiet
set :bundle_without,      []


def usage(*messages)
  STDERR.puts "Usage: cap deploy -S target=<host:/file/system>"  
  STDERR.puts messages.join("\n")
  STDERR.puts "You may set the remote user and group by using -S who=<user:group> (defaults to #{user}:#{group})."
  STDERR.puts "If you set the user, you must be able to ssh to the domain as that user."
  STDERR.puts "You may set the branch in a similar manner: -S branch=<branch name> (defaults to #{variables[:branch]})."
  exit
end

usage('The deployment target was not set (e.g., target=ripple.fcla.edu:/opt/web-services/sites/silos).') unless (variables[:target] and variables[:target] =~ %r{.*:.*})

_domain, _filesystem = variables[:target].split(':', 2)

set :deploy_to,  _filesystem
set :domain,     _domain

if (variables[:who] and variables[:who] =~ %r{.*:.*})
  _user, _group = variables[:who].split(':', 2)
  set :user, _user
  set :group, _group
end

role :app, domain

after "deploy:update", "deploy:cleanup"


