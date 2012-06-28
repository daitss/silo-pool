# -*- coding: utf-8; mode: ruby -*-

require 'open4'
require 'store/exceptions'
require 'store/utils'
require 'tempfile'
require 'time'
require 'timeout'

# Basic usage:
#
#  tsm = TsmExecutor.new('ADSM_TEST')        ; test tapes for us
#
#  tsm = TsmExecutor.new('BERNARD_SERVER')   ; production tapes for DAITSS
#  tsm.save my-path
#  if tsm.status != 0 ....
#
#
# No expected exceptions should be raised out of this class.  Instead,
# look at the status attribute, a fixnum:
#
#  *   0 Success.
#  *   4 General success, but some files were not processed
#  *   8 There were some warnings.
#  *  12 General failure.
#  * 253 Can't happen.
#  * 254 Failure in popen.
#  * 255 Timeout for dsmc.
#
# Use Tsm#output and Tsm#errors to investigate, and if necessary, log the situation.

module Store
  class TsmExecutor
    
    attr_reader :server, :dsmc, :command, :pid, :status
    
    # Store::TsmExecutor.new SERVERNAME, [ TIMEOUT ]
    # 
    #
    #  A pig is a jolly compainion,
    #  Boar, sow, barrow or gilt--
    #  A pig is a pal, who'll boost your morale,
    #  Though mountains may topple and tilt.
    #  When they've blackballed, bamboozled and burned you,
    #  When they've turned on you Tory and Whig,
    #  Though you may be thrown over by Tabby or Rover,
    #  You'll never go wrong with a pig, a pig,
    #  You'll never go wrong with a pig!
    
    def initialize  servername, timeout = nil
      @dsmc    = '/usr/bin/dsmc'
      @server  = servername
      @command = nil
      
      @default_timeout = timeout || 3600

      @errors_file = Tempfile.new 'dsm-errors'
      @output_file = Tempfile.new 'dsm-output'
    end

    def to_s
      "#<#{@dsmc}: server #{@server}, last command: #{@command}>"
    end

    # Deprecated:

    def self.tsm_path pathname
      pathname    = File.expand_path(pathname)
      pathname   += File::SEPARATOR if File.directory? pathname
      mount_point = StoreUtils.disk_mount_point(pathname)
      pathname.gsub %r{^#{mount_point}}, "{#{mount_point}}"
    end

    # timeout returns the default timeout for the TsmExecutor#delete, TsmExecutor#save, TsmExecutor#list and
    # TsmExecutor#restore commands.  It is optionally set on object creation.  

    def timeout
      @default_timeout
    end
    
    # def delete path, timeout = nil
    #   run_dsmc(timeout, dsmc, "delete", "backup",  "-noprompt",  "-servername=#{server}",  "-subdir=yes",  path)
    # end
    # 
    # note on deletes from tape, which are now deprecated:
    #
    # need do the two-pass delete as follows (need to be prepared for a 12 response code
    # here on -deltype=inactive)
    #
    # Me, on a condition noted in some test arrangements:
    #
    # >> When I list I get what I expect.  When I extract I get more than I
    # >> expect; some files that should have been deleted.   What's going on?
    #
    # Darryl:
    #
    # > Question:  Would there have been more than one version of those files
    # > backed up?  By default, delete backup only deletes the active version,
    # > and then your restore command, since it uses "-latest", would then
    # > see that the active version had been deleted and would thus restore
    # > the inactive version with the newest date.  If this is the case, then
    # > to delete all versions of a file, first issue the delete backup with
    # > -deltype=inactive, then issue the command again with -deltype=active.
    # > That's the only way to guarantee all versions of a file are deleted.
    # >
    # > Darryl
    # >
        
    def save path, timeout = nil
      run_dsmc(timeout, dsmc, "backup", "-servername=#{server}", "-subdir=yes", path)
      return TsmExecutor.tsm_path(path)
    end

    Struct.new('TivoliRecord', :path, :size, :mtime) 
    
    def list path, timeout = nil
      run_dsmc(timeout, dsmc, "query", "backup", "-detail", "-inactive", "-filesonly", "-servername=#{server}", "-scrollprompt=no", "-subdir=yes", path)

      state   = :other
      listing = []
      rec     = nil   # scoping

      return listing unless (status == 0 and errors.length == 0)

      output do |line|

        # Typical lines we'll be parsing from the tivoli output:
        #
        #          Size      Backup Date        Mgmt Class A/I File
        #          ----      -----------        ---------- --- ----
        #          0  B  07/13/2010 02:15:05    PERMANENT   A  /daitssfs/023/000/.lock
        #     	      Modified: 07/12/2010 18:22:25	Accessed: 10/28/2009 16:50:30
        # 19,251,200  B  03/02/2010 09:46:12    PERMANENT   A  /daitssfs/023/000/04a197ad3a00ee4bc98b78858ce4c/data
        #     	      Modified: 10/28/2009 16:50:30	Accessed: 02/25/2010 21:46:19
        # ...
        #         25  B  03/02/2010 22:33:17    PERMANENT   I  /daitssfs/023/ffe/c6562ea1af5f439234428aca9495c/type
        #             Modified: 11/02/2009 08:49:15	Accessed: 11/03/2009 04:09:02
        #
        # We want to parse the active backup file (marked A under A/I) and the following modified time, then
        # wrap into a nice tight struct..
        

        line.gsub!(/^\s+/, '')

        case state    
        when :other      # size     # units    # date                # time                # mgmt class    
          if line =~ %r{^([\d,]+)\s+([A-Z]+)\s+(\d{2}/\d{2}/\d{4})\s+(\d{2}:\d{2}:\d{2})\s+([A-Za-z0-9_-]+)\s+([A-Z]+)\s+(/.*)$} and $6 == 'A'
            path = $7
            units = $2
            size = $1.gsub(',', '').to_i
            case units.upcase    # normally in 'B', bytes.  We've had *one* *case* where this was 'KB'...
            when 'KB'
              size = size * 1024
            when 'MB'
              size = size * 1024 * 1024
            end
            rec = Struct::TivoliRecord.new(path, size, nil)
            state = :listing
          end
        when :listing                # modification date,  # time                            # access date,        # time
          if line =~ %r{^Modified:\s+(\d{2}/\d{2}/\d{4})\s+(\d{2}:\d{2}:\d{2})\s+Accessed:\s+(\d{2}/\d{2}/\d{4})\s+(\d{2}:\d{2}:\d{2})}
            rec.mtime = Time.parse($1 + ' ' + $2)
            listing.push rec
            state = :other
          end
        end  
      end  

      return listing.sort { |a, b| a.path <=> b.path }  
    end


    # Use the tivoli restore command: works for entire silos or components
    #
    #  * -filesonly on restore allow us to get around restrictive directory permissions on silos when saved (otherwise root is required)
    #  * -replace=no avoids the sticky issue of prompts: be sure to clear the target directory!
    #  * -subdir=yes means recurse into directories

    ###  * -latest just seems to make sense -- oops - that returns inactive as well....

    def restore path, destination, tivoli_owner,timeout = nil
      ### run_dsmc(timeout, dsmc, "restore", "-latest", "-replace=no", "-filesonly", "-servername=#{server}", "-subdir=yes", path, destination)
      path = '"' << path << "*"  << '"'

      #run_dsmc(timeout, dsmc, "restore", "-replace=no", "-filesonly", "-servername=#{server}", "-subdir=yes",  "-fromowner=fcldem" , "-optfile=/opt/tivoli/tsm/client/ba/bin/iraserv.opt", path, destination)
      #-worksrun_dsmc(timeout, dsmc, "restore", "-replace=no", "-filesonly", "-subdir=yes",  "-fromowner=fcldem" , "-optfile=/opt/tivoli/tsm/client/ba/bin/iraserv.opt", path, destination)
      run_dsmc(timeout, dsmc, "restore", "-replace=no", "-filesonly", "-subdir=yes",  "-fromowner=#{tivoli_owner}" , "-servername=#{server}", path, destination)
    end
    
    def output &blk
      handle_file @output_file, &blk
    end
    
    def errors &blk
      handle_file @errors_file, &blk
    end
    
    private
    
    def handle_file fio, &blk
      fio.rewind
      if blk
        while not fio.eof?
          yield fio.readline.chomp
        end
      else
        fio.readlines
      end
    end
        
    # We throw in our own status codes here:
    #
    # 255:  self-inflicted timeout error
    # 254:  error in popen (bad args, for example)
    # 253:  something's really odd.
    #
    # From the IBM manual:
    #
    #    Status code 0: All operations completed successfully.
    #
    #    Status code 4:  The operation completed successfully, but some files were not
    #    processed. There were no other errors or warnings. This return code is
    #    very common. Files are not processed for various reasons. The most
    #    common reasons are:
    #
    #      * The file satisfies an entry in an exclude list.
    #
    #      * The file was in use by another application and could not be 
    #        accessed by the client.
    #
    #      * The file changed during the operation to an extent prohibited by
    #        the copy serialization attribute. See “Copy serialization” on page
    #        215.
    #
    #    Status code 8: The operation completed with at least one warning
    #    message. For scheduled events, the status will be Completed. Review
    #    dsmerror.log (and dsmsched.log for scheduled events) to determine what
    #    warning messages were issued and to assess their impact on the
    #    operation.
    #
    #    Status code 12: The operation completed with at least one error
    #    message (except for error messages for skipped files). For scheduled
    #    events, the status will be Failed. Review the dsmerror.log file (and
    #    dsmsched.log file for scheduled events) to determine what error
    #    messages were issued and to assess their impact on the operation. As a
    #    general rule, this return code means that the error was severe enough
    #    to prevent the successful completion of the operation. For example, an
    #    error that prevents an entire file system or file specification from
    #    being processed yields return code 12.
    
    def run_dsmc timeout, *cmd
      timeout ||= @default_timeout 
      @command  = cmd.join(' ')
      @status   = nil
      [ @output_file, @errors_file ].each { |file| file.rewind;  file.truncate(0) }
      
      Timeout.timeout(timeout) do
        Open4.popen4(*cmd) do |@pid, process_in, process_out, process_err|
          output_thread = Thread.new { while data = process_out.gets; @output_file.write data; end }
          errors_thread = Thread.new { while data = process_err.gets; @errors_file.write data; end }
          output_thread.join
          errors_thread.join
        end
      end
      
    rescue Timeout::Error => e
      @status = -1
      @errors_file.write  "Execution of #{dsmc} timed out after #{timeout} seconds."
      begin 
        Process.kill(15, @pid) 
      rescue => e2
        @errors_file.write "The #{dsmc} process (process id #{@pid}) wasn't killable after a timeout: #{e2.message}."
      end

    rescue => e
      @status = -2  
      @errors_file.write "Error in popen4: #{e.message}."      

    else
      if $?.nil?
        @status = -3
        @errors_file.write "Unknown error running #{dsmc} (can't happen)."
      end
      
    ensure                    # get the original process exit status back; note: this re-maps our 
      @status = $?.to_i >> 8  # special codes: -1 => 255; -2 => 254, -3 => 253

    end # of run_dsmc    
  end # of TsmExecutor class
end # of Module Store
# Ta da!
