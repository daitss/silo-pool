# -*- coding: utf-8 -*-
#
# TODO: if we get a message with embedded newlines, break them out for the logging.

error do
  e = @env['sinatra.error']

  # Passenger phusion complains to STDERR about the dropped body data
  # unless we rewind. (would flush or close do? it would read better)

  request.body.rewind if request.body.respond_to?('rewind')  

  # The Store::HttpError classes carry along their own messages and
  # HTTP status codes.

  if e.is_a? Store::Http400Error
    Logger.warn e.client_message, @env
    [ halt e.status_code, { 'Content-Type' => 'text/plain' },  e.client_message ]
    

  elsif e.is_a? Store::ConfigurationError
    Logger.err e.client_message, @env
    [ halt 500, { 'Content-Type' => 'text/plain' }, e.client_message ]

  # Next are known errors with sufficient diagnostic  messages for the
  # user; they won't need backtraces.  It is important that kinds of 
  # messages not leak information.

  elsif e.is_a? Store::HttpError
    Logger.err e.client_message, @env
    [ halt e.status_code, { 'Content-Type' => 'text/plain' }, e.client_message ]
    
  # Anything else we catch here, log a back trace as well - minimal
  # information is provided in the browser.  In the limit, we'll
  # classify and catch all of these above. (Wherever you find "raise
  # 'message...'" sprinked in the code now, it awaits your shrewd
  # refactoring.)

  else
    Logger.err "Internal Server Error - #{e.class} #{e.message}", @env
    e.backtrace.each { |line| Logger.err line, @env }
    [ halt 500, { 'Content-Type' => 'text/plain' }, "Internal Service Error - See system logs for more information\n" ]
  end
end

# Urg.  The not_found method grabs *my* ( [ halt(404), ... ], a Bad
# Thing (© G R Fischer, 1956).  Repeat the code above for this special
# case.

not_found  do
  request.body.rewind if request.body.respond_to?('rewind')  
  e = @env['sinatra.error']
  message = if e.is_a? Store::Http404 
              e.client_message
            else
              "404 Not Found - #{request.url} doesn't exist.\n"
            end
  Logger.warn message, @env
  content_type 'text/plain'
  message
end
