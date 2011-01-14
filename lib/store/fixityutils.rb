
require 'store/exceptions'

# check_package_fixities CONF
#
# Recompute all checksums and record into a database.  Log error if we get
# a mismatch with a previous checksum.

def check_package_fixities web_server, silo_name, filesystem
  success = true

  Logger.info "Checking package fixities from the database records for silo #{silo_name} against the filesystem #{filesystem}."

  silo_record = Store::DB::SiloRecord.lookup(web_server, silo_name)
  silo        = Store::Silo.new(filesystem)

  silo.each do |package|
    begin

      package_record = Store::DB::PackageRecord.lookup(silo_record, package) 
      md5  = Digest::MD5.new
      sha1 = Digest::SHA1.new
      silo.get(package) do |buff|
        md5  << buff
        sha1 << buff 
     end
      md5  = md5.hexdigest
      sha1 = sha1.hexdigest
    rescue => e              # We attempt to continue from a single package error
      Logger.err "Fixity failure for package #{package} on #{filesytem}: #{e.message}."
      success = false
    else

      Store::DB::HistoryRecord.fixity(silo_record, package, :md5 => md5, :sha1 => sha1)   
      errors = []
      errors.push "database md5 mismatch - expected #{package_record.initial_md5} but got #{md5}"        if (md5  != package_record.initial_md5)
      errors.push "filesystem md5 mismatch - expected #{silo.md5(package)} but got #{md5}"               if (md5  != silo.md5(package))
      errors.push "database sha1 mismatch - expected #{package_record.initial_sha1} but got #{sha1}"     if (sha1 != package_record.initial_sha1)
      errors.push "filesystem sha1 mismatch - expected #{silo.sha1(package)} but got #{sha1}"            if (sha1 != silo.sha1(package))
      if errors.count > 0
         Logger.err  "Fixity failure for package #{package} belonging to silo #{silo_name} (checked at #{filesystem}): #{errors.join('; ')}."
         success = false
      end
    end
  end

  return success
rescue => e
  raise FatalFixityError, "Fixity check failure, #{e}"
end

# Provide a stream of all of the package names found on the silo restored to the scratch disk.

class SiloStream < ArrayBasedStream
  def initialize root
    @index = 0
    @list  = []
    silo = Store::Silo.new(root)
    silo.each { |name| @list.push [ name, true ] }
    @list.sort! { |a, b| a[0].downcase <=> b[0].downcase }
  end
end

# Provides a stream of all of the package names that our DB records for this
# silo.  The value returned indicates whether it still exists (true) or was
# deleted (false).

class DbStream  < ArrayBasedStream
  def initialize host, dir
    @index = 0
    @list  = []
    silo_record = Store::DB::SiloRecord.lookup(host, dir)
    Store::DB::PackageRecord.list(silo_record).each { |rec| @list.push [ rec.name, rec.extant ] }
    @list.sort! { |a, b| a[0].downcase <=> b[0].downcase }
  end
end


def pluralize_maybe count, singular, plural = nil
  plural ||= singular + 's'
  count == 1 ? singular : plural
end


# check_for_missing OPTIONS

# Compare these two data streams: package names from the database
# listing for <<web_server, silo>>, and for the packages that 
# are on the silo at filesystem.  We don't check checksums
# here.

# We return a struct with three elements, all integer-valued.
# It lists the number of missing, ghost, and alien files.
# Missing files are those listed in the DB as present but not found on disk.
# Ghosts are files the DB has marked as deleted, but we *did* find them on disk.
# Aliens are files found on disk that have no records at all on disk.
#
# In some cases, the presence of aliens or ghosts is not a big deal (say, found on 
# tape).  But it may indicate a problem - especially if they were on disk.

Struct.new('FileIssues', :ghosts, :missing, :aliens)

def check_for_missing web_server, silo, filesystem   ## TODO: rename to database_check
  info = Struct::FileIssues.new(0, 0, 0)

  Logger.info "Database check for missing, ghost and alien packages for the silo #{silo} on filesystem #{filesystem}."

  silo_stream = SiloStream.new(filesystem)
  db_stream   = DbStream.new(web_server, silo)

  missing  = []  # in db, but not on filesystem
  aliens   = []  # on filesystem, but not in db at all
  ghosts   = []  # on filesystem, but marked as deleted in db

  # on_disk is nil if package was not present on disk,  true otherwise
  # in_db is nil if no package record in db, false if package was marked as deleted, and true if it should exist   #### TODO: need better than true/false here

  ComparisonStream.new(silo_stream, db_stream).get do |package_name, on_disk, in_db|
    if on_disk.nil?
      missing.push package_name if in_db       # we don't care if not on disk and marked as deleted in the db;
    elsif in_db.nil?                           
      aliens.push package_name    
    else
      ghosts.push package_name  if not in_db   # It is on_disk, but is marked in the db as deleted - this will happen over time for silos restored from tapes,
    end                                        # but it indicates a real problem for disk silos.
  end

  if not ghosts.empty?
    info.ghosts = ghosts.count
    Logger.info "The filesystem #{filesystem} has #{info.ghosts} #{pluralize_maybe(ghosts.count, 'package')} that the database indicates have been deleted from #{silo}: package names follow:"
    ghosts.each_slice(5) { |slice| Logger.info slice.join(' ') }
  end
  
  if not aliens.empty?
    info.aliens = aliens.count
    Logger.info "The filesystem #{filesystem} has #{info.aliens} #{pluralize_maybe(aliens.count, 'package')} that the database for #{silo} has no record of, package names follow:"
    aliens.each_slice(5) { |slice| Logger.warn slice.join(' ') }
  end

  if not missing.empty?
    info.missing = missing.count
    Logger.err "The filesystem #{filesystem} is missing #{info.missing} #{pluralize_maybe(missing.count, 'package')} that the database for #{silo} indicates should be there, package names follow:"
    missing.each_slice(5) { |slice| Logger.err slice.join(' ') }
  end

  return info
rescue => e
  raise FatalFixityError, "Error while doing database checking for missing, alien or ghost packages: #{e}"
end


# clean_up_scratch_disk filesystem
#
# Attempt to remove all silo directories from the scratch disk.

def clean_up_scratch_disk filesystem

  Logger.info "Cleaning scratch disk #{filesystem}."

  targets = []
  Dir.open filesystem do |root|
    root.sort.each do |subdir|
      target = File.join(filesystem, subdir)
      next unless File.directory? target
      next unless subdir =~ %r{[a-f0-9]{3}}        # only target the top-level directories we expect
      targets.push target
    end
  end
  FileUtils.chmod_R 0777, targets
  FileUtils.rm_rf targets

rescue => e
  raise FatalFixityError, "Unable to remove directories from the scratch disk #{filesystem}: #{e.message}"
end


# restore_to_scratch_disk 
#
# restore the daitssfs silo from Tivoli to the scratch disk.

def restore_to_scratch_disk tape_server, silo, destination_directory

  silo = silo.gsub(%r{/+$}, '') + '/'
  destination_directory = destination_directory.gsub(%r{/+$}, '') + '/'

  Logger.info "Restoring silo #{silo} from tape to scratch disk #{destination_directory}."

  tsm = Store::TsmExecutor.new(tape_server)
  tsm.restore(silo, destination_directory, 16 * 60 * 60)   # Sixteen hours to restore - twice the expected time

  if tsm.status > 4
    Logger.err "Command '#{tsm.command}', exited with status #{tsm.status}"
    if not tsm.errors.empty?
      Logger.err "Tivoli error log follows:"
      tsm.errors.each { |line| Logger.err line.chomp }
    end
    if not tsm.output.empty?
      Logger.err "Tivoli output log follows:"
      tsm.output.each { |line| Logger.err line.chomp }
    end
    raise "fatal tivloi error"
  end
  
rescue => e
  raise FatalFixityError, "Restore failure: #{e}"
end



