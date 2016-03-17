#require 'pp'
OscTypes = [:i32, :f32, :s, :b, :u64, :f64, :S, :u8, :r, :m, :B]
$calls = 0

class Callable
    attr_reader :eval_value
    def initialize(ctx=nil)
        #t1 = Time.new
        @value = nil
        @eval_value = nil
        @ctx = ctx
        #if(!ctx.nil?)
        #    ctx.each do |key, val|
        #        inst_variable_name = "@#{method_name}".to_sym
        #        self.define_method key do
        #            val
        #        end
        #        #self.instance_eval("def #{key};@ctx[\"#{key}\"];end")
        #    end
        #end
        #puts "callable time is #{1000*(Time.new-t1)}ms"
    end
    def value=(x)
        @value = x
        @eval_value = nil
    end
    def eval_value=(x)
        if(x == "nil")
            return
        elsif(x == "true")
            @value = true
            return
        elsif(x == "false")
            @value = false
            return
        elsif(x == "[]")
            @value = []
            return
        elsif(x == "0")
            @value = 0
            return
        elsif(x == "1.0")
            @value = 1.0
            return
        elsif(x == "\"\"")
            @value = ""
            return
        end
        @value = nil
        @eval_value = x
        #print '.'
        #puts x[0..8]
        self.instance_eval("def get_value;#{@eval_value};end")
    end
    def call
        result = nil
        if(!@eval_value.nil? && !@eval_value.to_s.nil?)
            #$calls += 1
            #puts "call#{$calls}..."
            result = get_value
        else
            result = @value
        end
        result
    end

    def bind(object, property, expr)
        db = object.db
        db.connect_property(object.properties[property], expr, @ctx)
    end

    def registerExternal(x)
    end
    def method_missing(sym, *args, &block)
        #puts "Callable Method Missing on #{sym}"
        #puts "method missing"
        @ctx[sym.to_s]
    end
end

class ExternalDb
    attr_accessor :schema
    def event(uri)
    end
    def get(uri)
    end
    def set(uri)
    end
    def meta(uri)
    end

end

class Property
    def initialize(id, cb=nil)
        @ppath = "/ui/"
        @identifier = id
        @stale = true
        @different = false
        @selfDifferent = true
        @value = nil
        @depends = []
        @callback = cb
        @onWrite = []
        @rdepends = Set.new
    end

    def <=>(p)
        id <=> p.id
    end
    #Parent path
    attr_accessor :ppath
    #Debug Information on where property is defined
    attr_accessor :source
    #Fully qualified name of property
    attr_accessor :identifier
    #Local name of property
    attr_accessor :fieldname
    #Boolean property if this data is bound to a literal value
    attr_accessor :literal
    #List of known properties which this property reads from
    attr_accessor :depends
    #List of known properties which this property writes to
    attr_accessor :rdepends
    #Boolean property if this data is out-of-date
    attr_accessor :stale
    #Boolean property if this data has changed in the past frame
    attr_accessor :different
    #Boolean property for if the cb/literal value has changed
    attr_accessor :selfDifferent
    #Proc Callback for obtaining the new value
    attr_accessor :callback
    #Any value that the current object produces
    attr_accessor :value
    #Any value that the current object produced on the previous frame
    attr_accessor :oldValue
    #Container for onXYZ methods
    attr_accessor :onWrite

    def to_s()
        out = "#<Property:#{id}=#{@stale?"?":"XX"}"
        if(!@depends.empty?)
            out = out+"dep=#{@depends.each{|x|x.id}.join}"
        else
            out = out
        end
        if(callback.eval_value)
            if(callback.eval_value.length < 20)
                out = out+"callback=#{callback.eval_value}>"
            else
                out = out+"callback=#{callback.eval_value[0..20]}>"
            end
        else
            out = out+">"
        end
        #if(@rdepends.empty?)
        #    out+">"
        #else
        #    out+"rdep=#{@rdepends.to_a}>"
        #end
    end

    def id
        @ppath+@identifier
    end
end

class PropertyDatabase
    def initialize()
        @transaction_nest = 0
        @read_list = []
        @old_read_list = []
        @plist = []
        @stale_rdep_graph = true
    end

    def get_prop(identifier)
        prop = nil
        @plist.each do |x|
            if(x.id == identifier)
                prop = x
            end
        end
        prop
    end

    def load_id(identifier)
        #puts "Loading ID=#{identifier}"
        prop = get_prop identifier
        if(prop)
            load_property(prop)
        end
    end

    def update_dependency(prop, ndep)
        #puts("updating dep graph to #{ndep}")
        if(ndep.length == 0)
            prop.literal = true
        end
        if(ndep != prop.depends)
            @stale_rdep_graph = true
        end
        prop.depends = ndep
    end

    def load_property(prop)
        if(!prop.is_a? Property)
            puts "Invalid Property(LP):"
            #pp prop
            puts prop.class
            puts prop
        end
        #puts "[DEBUG] Loading #{prop.id} at transaction #{@transaction_nest}"
        if(@transaction_nest != 0)
            @read_list << prop
        end
        if(!prop.selfDifferent && !prop.stale)
            #puts "[DEBUG]    quick return #{prop.value}"
            return prop.value
        end
        plausably_different = prop.selfDifferent
        prop.depends.each do |x|
            if(x.stale)
                load_id(x)
            end
            plausably_different |= x.different
        end
        if(plausably_different)
            prop.oldValue = prop.value

            #puts "Original Dep(#{prop.identifier}) = #{prop.depends}"
            #puts "[DEBUG] Loading..."
            start_load_transaction()
            prop.value = prop.callback.call()
            read_list = end_load_transaction()

            #TODO react to prop.depends != @read_list
            #puts "New      Dep(#{prop.identifier}) = #{read_list}"
            if(read_list != prop.depends || prop.depends == [])
                update_dependency(prop, read_list)
            end

            prop.selfDifferent = false
            if(prop.value != prop.oldValue)
                prop.onWrite.each do |x|
                    x.call
                end
                prop.different = true
            else
                prop.different = false
            end
            prop.stale = false
        else
            prop.stale = false
        end
        #puts "[DEBUG]#{prop.identifier}[#{plausably_different}] = #{prop.value}"
        #puts "[DEBUG]    slow return #{prop.value}"
        prop.value
    end

    def make_stale(id)
        prop = get_prop id
        if(prop.stale)
            return
        end
        prop.stale = true
        @plist.each do |x|
            if(x.depends.include? prop)
                make_stale(x.identifier)
            end
        end
    end

    def write(id, cb)
        prop = get_prop id
        prop.callback = cb
        prop.selfDifferent = true
        make_stale id

        #needed for onWrite methods...
        load_property prop
        #prop.onWrite.each do |x|
        #    x.call
        #end
    end

    def write_property(p, value)
        if(!(p.is_a? Property))
            puts "Invalid property(WP):"
            puts p.class
            puts p
            #pp p
        end
        #Find all properties which are in the transitive closure of depending on
        #Property 'p'
        #puts "Updating callback to be '#{value}'"
        c = Callable.new
        c.value = value
        p.callback = c
        p.value = value
        p.stale = true
        p.different = true
        #transitive_closure
        make_rdepends
        propigate_stale p
    end

    def make_rdepends
        if(@stale_rdep_graph)
            print "making reverse graph"
            t1 = Time.new
            @plist.each do |x|
                x.rdepends = Set.new
            end
            @plist.each do |x|
                x.depends.each do |prop|
                    prop.rdepends << x
                end
            end
            t2 = Time.new
            puts "[#{@plist.length}]<#{1000*(t2-t1)} ms>"
            @stale_rdep_graph = false
        end
        #@plist.each do |x|
        #    puts "ID: #{x}"
        #    puts "   " + x.rdepends.to_s
        #end
    end

    def propigate_stale(src)
        src.stale = true
        src.rdepends.each do |prop|
            if(!prop.stale)
                propigate_stale prop
            end
        end
    end

    def connect_property(p, cb, context)
        #t1 = Time.new
        if(!(p.is_a? Property))
            puts "Invalid property(CP):"
            puts p.class
            puts p
            #pp p
        end
        if(cb.is_a? String)
            if(cb[0] == "{")
                cb = "begin\n"+cb[1..-2]+"\nend"
            end
            c = Callable.new(context)
            c.eval_value = cb
            p.callback = c
            p.stale = true
        else
            puts "I don't understand this connection..."
            puts cb.class
            pp cb
            throw :error
        end
        #puts "connection time is #{1000*(Time.new-t1)}ms"
    end

    def connect_watcher(p, cb, context)
        if(!(p.is_a? Property))
            puts "Invalid property(CP):"
            puts p.class
            puts p
            #pp p
        end
        if(cb.is_a? String)
            if(cb[0] == "{")
                cb = "begin\n"+cb[1..-2]+"\nend"
            end
            c = Callable.new(context)
            c.eval_value = cb
            p.onWrite << c
        else
            puts "I don't understand this connection..."
            puts cb.class
            puts cb
            throw :error
        end
    end

    def start_load_transaction()
        @transaction_nest += 1
        if(@read_list != [])
            @old_read_list.push @read_list
        end
        @read_list = []
    end
    def end_load_transaction()
        @transaction_nest -= 1
        read = @read_list
        if(@old_read_list.length > 1)
            @read_list = @old_read_list.pop
        else
            @old_read_list = []
            @read_list = []
        end
        read.sort.uniq
    end

    def to_s
        out = "#<ParameterDatabase"
        @plist.each do |p|
            if(p.literal)
                out += "\n" + p.to_s
            else
                out += "\n" + p.to_s
            end
        end
        out + ">"
    end

    def force_update()
        @plist.each do |x|
            x.stale         = true
            x.selfDifferent = true
        end
        update_values
    end

    def update_values()
        @plist.each do |x|
            if(x.callback == nil)
                next
            end
            #pp x
            load_property x
            #pp x
        end
    end

    def read(handle)
    end

    def add_property(prop)
        @plist << prop
    end
end
