require 'ruby-prof'
require_relative "../mruby-qml-parse/mrblib/main.rb"
require_relative "../mruby-qml-parse/mrblib/parse-types.rb"
require_relative "../mruby-qml-parse/mrblib/parser.rb"
require_relative "../mruby-qml-parse/mrblib/prog-ir.rb"
require_relative "../mruby-qml-parse/mrblib/prog-vm.rb"
require_relative "../mruby-qml-parse/mrblib/react-attr.rb"

#Stubs
module NVG
    def self.rgba(r,g,b,a)
        nil
    end
end
module OSC
    class RemoteMetadata
        def initialize(a,b)
        end
        def short_name
            "short_name"
        end
        def tooltip
            "tooltip"
        end
        def options
            ["a", "b", "c"]
        end
        def min
            127.0
        end
        def max
            0.0
        end
        def units
            ""
        end
        def scale
            :linear
        end
    end
    class RemoteParam
        def initialize(a,b)
        end
        def callback=(x)
        end
        def mode=(x)
        end
        def type=(x)
        end
        def set_min(x)
            127.0
        end
        def set_max(x)
            0.0
        end
        def set_scale(x)
        end
        def clean()
        end
    end
end
class NilClass
    def log_widget=(x)
    end
    def get_view_pos(x)
    end
end
require_relative "../mruby-zest/mrblib/draw-common.rb"

require "set"
require_relative "mrblib/build.rb"
require_relative "mrblib/database.rb"
require_relative "mrblib/loader.rb"

 
doTest

RubyProf.measure_mode = RubyProf::ALLOCATIONS
RubyProf.start
begin
    times = []
    (0..20).each do |i|
        t1 = Time.new
        db = PropertyDatabase.new
        mw = Qml::MainWindow.new(db)
        db.update_values
        testSetup(mw)
        db.update_values
        t2 = Time.new
        times << t2-t1
    end
    total = times.reduce {|a,b| a+b} 
    avg   = total/times.length
    puts "time to create is #{1000*avg}ms"
end
result = RubyProf.stop

# print a flat profile to text
printer = RubyProf::CallStackPrinter.new(result)
#printer = RubyProf::CallTreePrinter.new(result)
#printer.print(File.open("./log-dec-09-2016.txt","w"))
printer.print(File.open("./log-dec-29-2016.html","w"))
