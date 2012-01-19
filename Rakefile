# -*- mode:ruby; -*-

require 'fileutils'
require 'rake'
require 'rspec'
require 'rspec/core/rake_task'
require 'socket'

HOME    = File.expand_path(File.dirname(__FILE__))
LIBDIR  = File.join(HOME, 'lib')
TMPDIR  = File.join(HOME, 'tmp')
FILES   = FileList["#{LIBDIR}/**/*.rb", 'config.ru', 'app.rb']         # run yard/hanna/rdoc on these and..
DOCDIR  = File.join(HOME, 'public', 'internals')                       # ...place the html doc files here.

def dev_host
  Socket.gethostname =~ /romeo-foxtrot/
end


RSpec::Core::RakeTask.new do |task|
  task.rspec_opts = [ '--color', '--format', 'documentation' ] 
  ## task.rcov = true if Socket.gethostname =~ /romeo-foxtrot/   # do coverage tests on my devlopment box
end

begin
  require 'cucumber'
  require 'cucumber/rake/task'

  Cucumber::Rake::Task.new(:features) do |t|
    t.cucumber_opts = "--format pretty"
  end
  task :features
rescue LoadError
  desc 'Cucumber rake task not available'
  task :features do
    abort 'Cucumber rake task is not available. Be sure to install cucumber as a gem or plugin'
  end
end

module Tags
  RUBY_FILES = FileList['**/*.rb', '**/*.ru'].exclude("pkg")
end

namespace "tags" do
  task :emacs => Tags::RUBY_FILES do
    puts "Making Emacs TAGS file"
    sh "xctags -e #{Tags::RUBY_FILES}", :verbose => false
  end
end

task :tags => ["tags:emacs"]



# Rebuild bundler vendor files for local development.  This will build
# both a Gemfile.lock, which we check in, and a
# Gemfile.development.lock.  The gems go to an installation directory
# on the development host only.

desc "Reset bundles"
task :bundle do
  sh "rm -rf #{HOME}/bundle #{HOME}/.bundle #{HOME}/Gemfile.development.lock #{HOME}/Gemfile.lock"
  sh "mkdir -p #{HOME}/bundle"
###  sh "cd #{HOME}; bundle --gemfile Gemfile.development install --path bundle"
  sh "cd #{HOME}; bundle --gemfile Gemfile install --path bundle"
end



# Assumes git pushed out
if ENV["USER"] == "Carol"
  user = "cchou"
else
  user = ENV["USER"]
end

task :darchive do
  sh "cap deploy -S target=darchive.fcla.edu:/opt/web-services/sites/silos     -S who=#{user}:#{user}"
end

task :tarchive do
  sh "cap deploy -S target=tarchive.fcla.edu:/opt/web-services/sites/silos     -S who=#{user}:#{user}"
end

task :betasilo do
  sh "cap deploy -S target=tarchive.fcla.edu:/opt/web-services/sites/betasilos -S who=#{user}:#{user}"
end

task :ripple   do
  sh "cap deploy -S target=ripple.fcla.edu:/opt/web-services/sites/silos       -S who=#{user}:#{user}"
end

task :retsina   do
  sh "cap deploy -S target=retsina.fcla.edu:/opt/web-services/sites/silos       -S who=#{user}:#{user}"
end

desc "Generate documentation from libraries - try yardoc, hanna, rdoc, in that order."
task :docs do

  yardoc  = `which yardoc 2> /dev/null`
  hanna   = `which hanna  2> /dev/null`
  rdoc    = `which rdoc   2> /dev/null`

  if not yardoc.empty?
    command = "yardoc --quiet --private --protected --title 'Silo Service' --output-dir #{DOCDIR} #{FILES}"
  elsif not hanna.empty?
    command = "hanna --quiet --main XmlResolution --op #{DOCDIR} --inline-source --all --title 'Silo' #{FILES}"
  elsif not rdoc.empty?
    command = "rdoc --quiet --main XmlResolution --op #{DOCDIR} --inline-source --all --title 'Silo' #{FILES}"
  else
    command = nil
  end

  if command.nil?
    puts "No documention helper (yardoc/hannah/rdoc) found, skipping the 'doc' task."
  else
    FileUtils.rm_rf FileList["#{DOCDIR}/**/*"]
    puts "Creating docs with #{command.split.first}."
    `#{command}`
  end
end

desc "Hit the restart button for apache/passenger, pow servers"
task :restart do
  sh "touch #{HOME}/tmp/restart.txt"
end


defaults = [:restart, :spec]
defaults.push :etags   if dev_host

task :default => defaults
