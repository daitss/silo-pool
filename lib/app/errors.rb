# -*- coding: utf-8 -*-

error do
  e = @env['sinatra.error']

  # Passenger phusion complains to STDERR about the dropped body data
  # unless we rewind.

  rewind_maybe

  # The Store::HttpError exception classes have HTTP status codes and
  # status messages attached; our application-specific exceptions subclass
  # these http exceptions; here's an example inheritance tree for one 
  # such application exception:
  #
  # StandardError => HttpError => Http400Error => Http413 => NoSilosLargeEnough
  #
  # When the application code finds no room for a store request, it raises
  # NoSilosLargeEnough with a detailed message: "There are no writable
  # silos in this pool with space for a package of size <number>";  We'll
  # automatically send this message to client with HTTP status 413.
  #
  # So here's how we handle these issues:
  #
  # 1) check for specific Http errors that require special handling, like authentication errors
  # 2) check for an Http400Error (that is, all Http4xxx errors)
  # 3) configuration errors (not subclassed from HttpError)
  # 4) any HtppError at all
  # 5) anything else gets a backtrace sent to the logs (not the client: don't want to leak sensitive info!)

  case

  # Not authenticated for a password-protected service; we need to add some
  # header info for the client:

  when e.is_a?(Store::Http401)
    Datyl::Logger.warn e.client_message, @env
    response['WWW-Authenticate'] = "Basic realm=\"Password-Protected Pool for\ #{hostname}\""
    halt e.status_code, { 'Content-Type' => 'text/plain' },  e.client_message

  # We usually administratively disable DELETEs and PUTs to be
  # safe. Sometimes we mistakenly forget to allow them when we've)
  # started, say, a batch refresh. That will leave orphans as the
  # superseded resource fails to be deleted; We'll log an error so we
  # can catch that quickly with our log monitoring material.

  when (e.is_a?(Store::Http405) and [ 'DELETE', 'PUT', 'POST' ].include?(request.request_method))
    Datyl::Logger.err e.client_message, @env
    halt e.status_code, { 'Content-Type' => 'text/plain' },  e.client_message

  # Any other 4xx error; but see not_found below!
    
  when e.is_a?(Store::Http400Error)
    Datyl::Logger.warn e.client_message, @env
    halt e.status_code, { 'Content-Type' => 'text/plain' },  e.client_message

  # Configuration errors messages are likely to be sensitive but
  # everything should be nailed down quickly durring setup, so we err
  # on the side of helpfulness and display the message in the browser:

  when e.is_a?(Store::ConfigurationError)
    Datyl::Logger.err e.client_message, @env
    halt 500, { 'Content-Type' => 'text/plain' }, e.client_message

  # Next are any other errors with safe, sufficiently informative messages for
  # the user they won't need backtraces.  It is important that these kinds
  # of messages not leak sensitive information.

  when e.is_a?(Store::HttpError)
    Datyl::Logger.err e.client_message, @env
    halt e.status_code, { 'Content-Type' => 'text/plain' }, e.client_message
    
  # Anything else we catch here, log a back trace as well - minimal
  # information is provided in the browser, to avoid leaking
  # security-sensitive information.  In the limit, we'll classify and
  # catch all of these above. (Wherever you find "raise 'message...'"
  # sprinked in the code now, it awaits your shrewd refactoring.)

  else
    Datyl::Logger.err "Internal Server Error - #{e.class} #{e.message}", @env
    e.backtrace.each { |line| Datyl::Logger.err line, @env }
    halt 500, { 'Content-Type' => 'text/plain' }, "Internal Service Error - See system logs for more information\n"
  end
end

# Urg.  The default not_found method seems to intercept 404 errors, so
# repeat what the 4** handler above does for this one case.


not_found  do
  rewind_maybe

  err = @env['sinatra.error']
  message = err.is_a?(Store::Http404) ? err.client_message : "404 Not Found - #{request.url} doesn't exist.\n"
  Datyl::Logger.warn message, @env
  content_type 'text/plain'
  message
end
