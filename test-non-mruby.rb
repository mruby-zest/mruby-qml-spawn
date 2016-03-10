require_relative "../mruby-qml-parse/mrblib/main.rb"
require_relative "../mruby-qml-parse/mrblib/parse-types.rb"
require_relative "../mruby-qml-parse/mrblib/parser.rb"
require_relative "../mruby-qml-parse/mrblib/prog-ir.rb"
require_relative "../mruby-qml-parse/mrblib/prog-vm.rb"
require_relative "../mruby-qml-parse/mrblib/react-attr.rb"

require "set"
require_relative "mrblib/build.rb"
require_relative "mrblib/database.rb"
require_relative "mrblib/loader.rb"

doTest
