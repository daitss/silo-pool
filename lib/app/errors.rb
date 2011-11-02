# -*- coding: utf-8 -*-

error do
  e = @env['sinatra.error']

  # Passenger phusion complains to STDERR about the dropped body data
  # unless we rewind.

  rewind_maybe

  # The Store::HttpError classes carry along their own messages and
  # HTTP status codes, so we won't need a backtrace:

  if e.is_a? Store::Http401
    Logger.warn e.client_message, @env
    response['WWW-Authenticate'] = "Basic realm=\"Password-Protected Pool for\ #{hostname}\""
    halt e.status_code, { 'Content-Type' => 'text/plain' },  e.client_message

  elsif e.is_a? Store::Http400Error   # see not_found below
    Logger.warn e.client_message, @env
    halt e.status_code, { 'Content-Type' => 'text/plain' },  e.client_message

  # No backtrace needed for configuration errors; the messages are sensitive
  # but everything should be nailed down quickly durring setup, so we err on
  # the side of helpfulness

  elsif e.is_a? Store::ConfigurationError
    Logger.err e.client_message, @env
    halt 500, { 'Content-Type' => 'text/plain' }, e.client_message

  # Next are known errors with safe, sufficiently informative messages for
  # the user; they won't need backtraces.  It is important that these kinds
  # of messages not leak sensitive information.

  elsif e.is_a? Store::HttpError
    Logger.err e.client_message, @env
    halt e.status_code, { 'Content-Type' => 'text/plain' }, e.client_message
    
  # Anything else we catch here, log a back trace as well - minimal
  # information is provided in the browser, to avoid leaking
  # security-sensitive information.  In the limit, we'll classify and
  # catch all of these above. (Wherever you find "raise 'message...'"
  # sprinked in the code now, it awaits your shrewd refactoring.)

  else
    Logger.err "Internal Server Error - #{e.class} #{e.message}", @env
    e.backtrace.each { |line| Logger.err line, @env }
    halt 500, { 'Content-Type' => 'text/plain' }, "Internal Service Error - See system logs for more information\n"
  end
end

# Urg.  The default not_found method seems to intercept 404 errors, so
# repeat what the 4** handler above does for this one case.


not_found  do
  rewind_maybe

  err = @env['sinatra.error']
  message = err.is_a?(Store::Http404) ? err.client_message : "404 Not Found - #{request.url} doesn't exist.\n"
  Logger.warn message, @env
  content_type 'text/plain'
  message
end
