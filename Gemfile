source "http://rubygems.org"

gem 'mime-types', :require => 'mime/types'
gem 'data_mapper',          '>= 1.0.0'
gem 'dm-mysql-adapter',     '>= 1.0.0'


case RUBY_PLATFORM
when /darwin/
  gem 'dm-postgres-adapter', :path => '/Library/Ruby/Gems/1.8/gems/dm-postgres-adapter-1.0.2'
else
  gem 'dm-postgres-adapter',  '>= 1.0.2'
end

gem 'builder',              '>= 2.1.0'
gem 'log4r',                '>= 1.1.5'
gem 'open4',                '>= 1.0.1'
gem 'sinatra',              '>= 1.0.0'
gem 'sys-filesystem',       '>= 0.3.2'

# development

gem 'ci_reporter',      '>= 1.6.2'
gem 'cucumber',		'>= 0.8.5'
gem 'rspec',		'>= 1.3.0'

