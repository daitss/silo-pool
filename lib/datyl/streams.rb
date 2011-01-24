require 'nokogiri'
require 'net/http'
require 'uri'

class ArrayBasedStream

  # This must be subclassed  must set @index, @list in constructor

  def initialize
    raise NotImplementedError 'This class is abstract...well, surreal'
  end

  def rewind
    @index = 0
  end

  def close
    @index = 0
  end

  def get
    if block_given?
      yield nil if eos?
      while not eos?
        yield *(@list[@index])
        @index += 1
      end
    elsif eos?
      return nil
    else
      @index += 1
      return *(@list[@index-1])
    end
  end

  def eos?
    @index > @list.length - 1
  end
end


Struct.new('FixityRecord', :md5, :sha1, :time)

# <?xml version='1.0' encoding='UTF-8'?>
# <silocheck fixity_check_count='2193' silo='/daitssfs/001' last_fixity_check='2010-06-05T04:01:52-04:00' first_fixity_check='2010-06-04T18:54:33-04:00' host='silos.darchive.fcla.edu' xmlns='info:fischers-hacks'>
#   <fixity name='E20060312_AAAACM' time='2010-06-05T00:05:24-04:00' sha1='2dfc65b44a37ec7759dfcb7fb066146ab4691d4d' md5='941b2e11be142cd519585d700e30fdb9' status='ok'/>
#   <fixity name='E20060312_AAAACN' time='2010-06-04T20:22:01-04:00' sha1='e90de635727ca28a183e45f0749e8f703fb9c20b' md5='49298aec9c29164a5718444cd40f1f6b' status='ok'/>
#   ...
# </silocheck>


# Given a URL for getting fixity data, return a list of name/hash pairs where the name is an IEID
# and the struct has fields for md5, sha1, and iso8601 timestamp (a string).

class SiloFixityStream < ArrayBasedStream

  # Create the SAX parser callback class that will find all of the fixity records from our web server

  class FixityXml < Nokogiri::XML::SAX::Document

    attr_reader :fixity_records

    def initialize
      @fixity_records = []
      super()
    end

    def start_element element_name, attributes = []
      return unless element_name.downcase == 'fixity'
      time = name = sha1 = md5 = nil
      while not attributes.empty?
        case attributes.shift.downcase
        when 'name';   name = attributes.shift
        when 'md5';    md5  = attributes.shift
        when 'sha1';   sha1 = attributes.shift
        when 'time';   time = attributes.shift
        end
      end
      @fixity_records.push [ name, Struct::FixityRecord.new(md5, sha1,time) ]
    end
  end # of class FixityXml


  attr_reader :list

  def initialize url
    document = FixityXml.new()
    Nokogiri::XML::SAX::Parser.new(document).parse(fetch(url))
    @list = document.fixity_records.sort{ |a,b| a[0] <=> b[0] }           # this works fast enough on our largest lists.
    @index = 0
  end
    
  private 

  def fetch location, limit = 5                                                                                                                                             
    uri = URI.parse location
                                                                                                                                                                              
    raise "#{location} can't be retrieved, there were too many redirects." if limit < 1

    Net::HTTP.start(uri.host, uri.port) do |http|
      http.read_timeout = 600
      response  = http.get(uri.path)
      case response
      when Net::HTTPSuccess     then return response.body
      when Net::HTTPRedirection then fetch response['location'], limit - 1
      else
        response.error!
      end
    end
  end # of fetch                                                                                                                                                            


end # of class SiloFixityStream


class FileStream  # file of text, whitespace-separated columns, first column is unique, sorted key.  Really meant to be subclassed.

  def initialize io
    @io = io
    @sep = /\s+/
  end

  def get
    if block_given?
      while not io.eof?
        yield @io.gets.chomp.split(/\s+/, 2)
      end
    else
      @io.gets.chomp.split(/\s+/, 2)
    end
  end

  def eos?
    @io.eof?
  end
end

# Class ComparisonStream is initialized with two streams - each stream
# should be thought of as a list of two-element arrays.  The first
# element is key (a string), and the second element is the value for
# that key (any object). A key is unique within a list. Each list is
# sorted on its keys.
#
# This class provides a block method that compares two such
# streams. It works by a merge-like operation on the unique keys of
# the lists, yielding at each merged record three elements.  The first
# element is the unique key, followed by its corresponding value from
# the first stream and the value from the second stream.  If a stream
# has no corresponding value for a key, nil is returned. At most one
# element will be nil, of course.
#
# This can give us a convienent way to determine, in one very quick
# pass, both missing packages and orphaned packages, as well as
# comparing the expected and actual checksums.

class ComparisonStream

  def initialize stream1, stream2
    @stream1 = stream1
    @stream2 = stream2
  end

  def rewind
    @stream1.rewind
    @stream2.rewind
  end

  def close
    @stream1.close if @stream1.respond_to? :close
    @stream2.close if @stream2.respond_to? :close    
  end


  KEY = 0
  VALUE = 1

  def get
    left_hand  = get_lhs()
    right_hand = get_rhs()

    while left_hand or right_hand

      if left_hand.nil?
        yield right_hand[KEY], nil, right_hand[VALUE]
        right_hand = get_rhs()

      elsif right_hand.nil?
        yield left_hand[KEY], left_hand[VALUE], nil
        left_hand = get_lhs()

      else
        case left_hand[KEY] <=> right_hand[KEY]

        when -1
          yield left_hand[KEY], left_hand[VALUE], nil
          left_hand = get_lhs()

        when 0
          yield left_hand[KEY], left_hand[VALUE], right_hand[VALUE]
          left_hand  = get_lhs()
          right_hand = get_rhs()

        when 1
          yield right_hand[KEY], nil, right_hand[VALUE]
          right_hand = get_rhs()
        end
      end
    end
  end  # of get

  private

  def get_lhs
    @stream1.eos? ? nil : @stream1.get
  end

  def get_rhs
    @stream2.eos? ? nil : @stream2.get
  end
end

