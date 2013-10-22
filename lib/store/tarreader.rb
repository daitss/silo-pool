require 'store/exceptions'
require 'digest/md5'

module Store

  class TarIO   # duck types an IO object for an individual file within a tar archive

    IO_BUFFER_SIZE = 1024 ** 2

    # TarIO.new(IO, FILE_START_POSITION, FILE_SIZE) where IO is an IO object opened on the tar archive; 
    # FILE_START_POSITION is the offset into the tar archive of the file of interest in the archive; 
    # FILE_SIZE is the length of that file.

    def initialize io, file_start_position, file_size 
      @io = io
      @file_start_position = file_start_position
      @file_size = file_size
      @bytes_consumed = 0
    end    

    def size
      @file_size
    end

    # no ops: 

    def close *args ; end
    def open  *args ; end

    def rewind 
      @bytes_consumed = 0
    end

    # TarIO.READ() returns the entire file, or an empty string if it is zero-length
    # TarIO.READ(SIZE) returns a buffer up to size bytes, or nil if there is nothing left to read

    def read size = nil
      if size
        return read_with_size(size)                           # returns nil if all read
      else
        buff = read_with_size(@file_size - @bytes_consumed)   # always return a string, even an empty string if nothing left
        return buff.nil?  ? "" : buff
      end
    end

    # mostly for rack....

    def each
      while (buff = read(IO_BUFFER_SIZE))
        yield buff
      end
    end

    private

    def read_with_size size  
      return nil if @bytes_consumed >= @file_size            
      size = [size, @file_size - @bytes_consumed].min                 # ready...
      @io.seek(@file_start_position + @bytes_consumed, IO::SEEK_SET)  #        ...aim...
      buff = @io.read(size)                                           #                ...fire
      @bytes_consumed += buff.size                                    
      return buff                                            
    end




  end  # of class TarIO

  class TarReader

    # TarReader is a utility class that lets us enumerate through the regular files in a tar file; we'll
    # get two things from each yield in a loop - the name of the tar file, and a form of IO (quack)
    # that lets us rewind to the beginning of the named file in the tar archive, as well as giving us a closed
    # condition when we get to the end of that file.  It's primarily used to read through tarfiles and check
    # MD5 checksums against a database.
    #
    # e.g.:
    #
    # TarReader.new('my.tar').each do |name, io|
    #   DoSomething(name, io.read)...
    # end
    #
    # We expect a USTAR archive but support some of the important GNU tar extensions: namely large file sizes
    # and long file names.
    #
    # We do not support hard links, symlinks, long symlink names, special files (devices and FIFOs), or 
    # sparse files (this last might bite us some day).


    include Enumerable

    attr_reader :filename, :headers
    BUFFSIZE = 1048576

    def initialize file_path
      @headers  = []
      @filename = file_path   # the tar file name
      @io       = open(file_path)
      @md5      = nil
      end_state = false
      offset    = 0
      last_entry_supplied_long_name = false   

      while (header = @io.read(512))  # read the next file header
        offset += 512                 # keep track of having read the header

        if header == 0.chr * 512      # a tar file is padded at the end with 2 or more null 512-byte blocks
          end_state = true
          next
        elsif end_state               # TODO: strictly speaking, we should properly ignore trailing garbage after two sets of 512-byte blocks
          raise TarReaderError, "Error reading the final bits of #{file_path} - tar file is corrupted."
        end

        metadata = parse_file_header header

        metadata['offset'] = offset            # where our file starts in the tar archive

        # TODO: strictly speaking, we must have a regular file as current entry, or we have an error:

        if last_entry_supplied_long_name       # last tar archive entry was actually a long name for this entry
          metadata['filename'] = last_entry_supplied_long_name
          last_entry_supplied_long_name = false
        end

        if metadata['type'] == 'long file name'                            # this tarchive entry is supplying a long name for next entry
          last_entry_supplied_long_name = @io.read(metadata['size'] - 1)   # so remember the name less the null
        end

        offset += round_to_block(metadata['size'])   # set offset to skip over the (padded) file data
        @io.seek(offset, IO::SEEK_SET)               # and position to the next tar archive header

        @headers.push metadata
      end

    rescue => e
	    puts e.backtrace
      raise TarReaderError, "Error reading file #{file_path}: #{e.class} #{e.message}"
    end

    # EACH  yields the pair (file-name, io-object) for each regular file in the archive;

    def each
      headers.each do |h|
        next unless h['type'] == 'regular file'
        yield h['filename'], TarIO.new(@io, h['offset'], h['size'])
      end
    end

    def md5
      return @md5 if @md5
      @io.rewind
      md5 = Digest::MD5.new    
      while (buff = @io.read BUFFSIZE)
        md5 << buff
      end
      return @md5 = md5
    end
    
    def io
      @io.rewind
      @io
    end


    private

    # ROUND_TO_BLOCK(NUM) takes the positive fixnum NUM and rounds up to the next multiple of 512 
    # (unless, of course, NUM is already a multiple of 512).  Headers and files within a tar file
    # all start on 512-byte boundries.

    def round_to_block num
      num.modulo(512) == 0 ? num : 512 * (1 + num.div(512))
    end

    # STRIP_NULLS(BUFF) takes a byte buffer BUFF and strips off everything after the first null, inclusive.  
    # It returns the original string if no null characters are present.  It returns nil for an empty string
    # or a string starting a null character.

    def strip_nulls buff
      buff.to_s.split(/#{0.chr}/)[0]
    end

    # OCT_MAYBE(STR) takes a string STR, presumably an octal representation of number, and returns it as a fixnum.
    # If STR is nil or false, return STR.

    def oct_maybe str
      return unless str
      str.oct
    end

    # COMPUTE_HEADER_CHECKSUM(BUFF) returns the computed checksum of the supplied 512-byte USTAR tar file header BUFF.
    # The location of the checksum itself (at buff[148..155]) is treated as a string of blanks.

    def compute_header_checksum buff
=begin	    
      sum =  0
      (0   .. 147).each { |i| sum += buff[i] }
      (156 .. 511).each { |i| sum += buff[i] }
      sum + 32 * 8   
=end
      sum = buff[0 .. 147].sum + buff[156 .. 511].sum
      sum + 32 * 8
    end

    # CONVERT_FROM_BINARY_MAYBE(BUFF) returns a number (a fixnum) extracted from the string BUFF
    #
    # USTAR standard requires, for portability, that numbers are ASCII strings encoded as an octal number.
    # So, for instance a file of size 17531044  we'd get the string "00102700244\000" in the 12-byte size 
    # field (octal "102700244" after stripping the NULL).
    #
    # Unfortunately, that means certain fields, such as the size, are limited to maximum lengths that are
    # inappropriate in today's environment (e.g. an 8GB max size for files, for the 12-byte header field). 
    #
    # Here we check for a GNU tar extension which indicates binary data by setting the first bit of the 
    # string. For instance, this was the 12-byte data for the file size field for test file I created of 
    # exactly 9GB: 
    #    "\200\000\000\000\000\000\000\002@\000\000\000"
    # This binary format allows 95 bits to be used for the file size field.


    def convert_from_binary_maybe buff
      if buff[0].to_i & 0b1000_0000 == 0b1000_0000
        s = buff[0].to_i & ~ 0b1000_0000                                       # mask out high bit
        (1..(buff.length - 1)).each { |i| s = 256 * s + buff[i] }         # Horner's algorithm
        return s
      else
        return strip_nulls(buff).oct    
      end
    end


    # PARSE_FILE_HEADER(BUFF) parses the 512-byte data block BUFF as ustar header data, and returns a hash with good stuff in it:
    #
    # filename    as string
    # offset      as fixnum, the offset into the tar archive for the beginning of this file
    # mode        as string with octal representation of this file's permission/mode bits
    # user        as fixnum UID
    # group       as fixnum GID
    # size        as fixnum, the length of this file
    # mtime       as Time object, the modification time of this file
    # type        the string 'regular file', 'directory', 'long file name', etc
    # user_name   the string giving the user name of the file
    # group_name  the string giving the group name of the file
    # etc...
    #
    # It throws an error if the file appears corrupt or not a tar file.


    def parse_file_header buff
      data = {}

      raise TarReaderError, "TarReader: Not a tar file (only USTAR format files (with some GNU tar extensions) are supported)." \
        unless strip_nulls(buff[257..261]) == 'ustar'

      data['checksum'] = strip_nulls(buff[148..155]).oct
      actual_checksum  = compute_header_checksum buff

      raise TarReaderError, "TarReader: computed header checksum #{actual_checksum} doesn't match expected checksum #{data['checksum']} (tar file corrupted)." \
        unless actual_checksum == data['checksum']
        
      data['filename'] = strip_nulls(buff[0..99])
      data['mode']     = strip_nulls(buff[100..107])
      data['user']     = strip_nulls(buff[108..115])
      data['group']    = strip_nulls(buff[116..123])
      data['size']     = convert_from_binary_maybe(buff[124..135])
      data['mtime']    = Time.at(strip_nulls(buff[136..147]).oct)
      data['linkname'] = strip_nulls(buff[157..256])

      data['type']  = case buff[156..156]
                      when '0' ; 'regular file'
                      when '1' ; 'hard link'
                      when '2' ; 'symbolic link'
                      when '3' ; 'character special'
                      when '4' ; 'block special'
                      when '5' ; 'directory'
                      when '6' ; 'fifo'
                      when 'L' ; 'long file name'  # an extension that means the contents of this file is actually the file name of the next tar entry, which must be a regular file
                      else buff[156..156]          # plenty of other extensions here, none of which we care about
                      end
  
      data['ustar version']       = strip_nulls(buff[263..264])
      data['user name']           = strip_nulls(buff[265..296])
      data['group name']          = strip_nulls(buff[297..328])
      data['device major number'] = oct_maybe strip_nulls(buff[329..336])
      data['device minor number'] = oct_maybe strip_nulls(buff[337..344]) 
      data['filename prefix']     = strip_nulls(buff[345..499])          # huh. GNU tar doesn't use at all for long filenames? Or for something else?

      # Not sure whether it is wise to use the standard here:

      data['filename'] = data['filename'] + "/" + data['filename prefix'] if not data['filename prefix'].nil?

      return data
    end

  end # of TarReader class
end # of Store module


