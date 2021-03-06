require 'ostruct'

# When we deploy with Capistrano it checks out the code using Git
# into its own branch, and places the git revision hash into the
# 'REVISION' file.  Here we search for that file, and if found, return
# its contents.

def get_capistrano_git_revision
  revision_file = File.expand_path(File.join(File.dirname(__FILE__), '..', 'REVISION'))
  File.exists?(revision_file) ? File.readlines(revision_file)[0].chomp : 'Unknown'
end

# When we deploy with Capistrano, it places a newly checked out
# version of the code into a directory created under ../releases/,
# with names such as 20100516175736.  Now this is a nice thing, since
# these directories are backed up in the normal course of events: we'd
# like to include this release number in our service version
# information so we can easily locate the specific version of the
# code, if need be, in the future.
#
# Note that this release information is more specific than a git
# release; it includes configuration information that may not be
# checked in.

def get_capistrano_release
  full_path = File.expand_path(File.join(File.dirname(__FILE__)))
  (full_path =~ %r{/releases/((\d+){14})/}) ? $1 : "Not Available"
end


module Store

  REVISION = get_capistrano_git_revision()
  RELEASE  = get_capistrano_release()
  VERSION  = File.read(File.expand_path("../../VERSION",__FILE__)).strip
  NAME     = 'Silo-Pool Service'

  def self.version
    os = OpenStruct.new("name"   => "#{NAME} Version #{VERSION}, Git Revision #{REVISION}, Capistrano Release #{RELEASE}",
                        "uri"    => "info:fcla/daitss/silo/#{VERSION}")
  end
end
