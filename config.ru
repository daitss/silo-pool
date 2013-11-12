# -*- mode: ruby; -*- 

require 'rubygems'
require 'bundler/setup'

$LOAD_PATH.unshift File.join File.dirname(__FILE__), 'lib'

require 'sinatra'
require './app'

run Sinatra::Application
