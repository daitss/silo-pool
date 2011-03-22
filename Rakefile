# -*- mode:ruby; -*-

require 'fileutils'
require 'rake'
require 'rake/rdoctask'
require 'socket'
require 'spec/rake/spectask'

# require 'bundler/setup'

spec_dependencies = []

begin
  require 'ci/reporter/rake/rspec' 
rescue LoadError => e
else
  spec_dependencies.push "ci:setup:rspec"
end  

task :spec => spec_dependencies

Spec::Rake::SpecTask.new do |task|
  task.libs << 'lib'
  task.libs << 'spec'
# task.rcov = true if Socket.gethostname =~ /romeo-foxtrot/   # do coverage tests on my devlopment box
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

HOME    = File.expand_path(File.dirname(__FILE__))
LIBDIR  = File.join(HOME, 'lib')
TMPDIR  = File.join(HOME, 'tmp')
FILES   = FileList["#{LIBDIR}/**/*.rb", 'config.ru', 'app.rb']         # run yard/hanna/rdoc on these and..
DOCDIR  = File.join(HOME, 'public', 'internals')                       # ...place the html doc files here.

# Rebuild bundler vendor files for local development (capistrano invokes bundler remotely).
# This will rebuild the Gemfile.lock, which we check in, but place the gems under the local
# vendor/ tree....

desc "Reset bundles"
task :bundle do
  sh "rm -rf #{HOME}/vendor/bundle"
  sh "mkdir -p #{HOME}/vendor/bundle"
  sh "cd #{HOME}; bundle install --path vendor/bundle"
end

# assumes git pushed out

desc "deploy to darchive's betasilos"
task :darchive_beta do
    sh "cap deploy -S target=darchive:/opt/web-services/sites/betasilos -S who=silo:daitss"
end

desc "deploy to darchive's production silos"
task :darchive_production do
    sh "cap deploy -S target=darchive:/opt/web-services/sites/silos -S who=silo:daitss"
end

# assumes git pushed out

desc "deploy to tarchive's production silos"
task :tarchive_production do
  sh "cap deploy -S target=tarchive:/opt/web-services/sites/betasilos -S who=silo:daitss"
end

desc "deploy to tarchive's betasilos"
task :tarchive_beta do
  sh "cap deploy -S target=tarchive:/opt/web-services/sites/betasilos -S who=silo:daitss"
end

desc "deploy to tarchive's gammasilos"
task :gamma_gamma do
  sh "cap deploy -S target=tarchive:/opt/web-services/sites/gammasilos -S who=silo:daitss"
end

desc "Deploy to ripple's test silos"
task :ripple do
 sh "cap deploy -S target=ripple:/opt/web-services/sites/silos -S who=silo:daitss"
end

desc "Deploy to franco's silos on ripple"
task :francos do
  sh "cap deploy -S target=ripple:/opt/web-services/sites/francos-silos -S who=daitss:daitss"
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

desc "Maintain the sinatra tmp directory for automated restart (passenger phusion pays attention to tmp/restart.txt) - only restarts if necessary"
task :restart do
  mkdir TMPDIR unless File.directory? TMPDIR
  restart = File.join(TMPDIR, 'restart.txt')     
  if not (File.exists?(restart) and `find "#{HOME}" -type f -newer "#{restart}" 2> /dev/null`.empty?)
    File.open(restart, 'w') { |f| f.write "" }
  end  
end

task :default => [:restart, :tags]
