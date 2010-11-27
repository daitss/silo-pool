# -*- mode:ruby; -*-

require 'fileutils'
require 'rake'
require 'rake/rdoctask'
require 'socket'
require 'spec/rake/spectask'


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


# Rebuild bundler

desc "Reset bundles"
task :bundle do
  `rm -rf #{HOME}/vendor/bundle`
  `mkdir -p #{HOME}/vendor/bundle`
  `cd #{HOME}; bundle install --path vendor/bundle`
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

# Build local (not deployed) bundled files for in-place development.

desc "Reset bundles"
task :bundle do
  `rm -rf #{HOME}/vendor/bundle`
  `mkdir -p #{HOME}/vendor/bundle`
  `cd #{HOME}; bundle install --path vendor/bundle`
end

desc "Create a marker file in the sinatra tmp directory that turns on profiling - restart to turn off"
task :profile do
  mkdir TMPDIR unless File.directory? TMPDIR
  profile = File.join(TMPDIR, 'profile.txt')     
  File.open(profile, 'w') { |f| f.write "" }
end



task :default => [:restart, :tags]
