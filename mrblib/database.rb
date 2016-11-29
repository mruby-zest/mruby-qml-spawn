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
    end
    def value=(x)
        @value = x
        @eval_value = nil
    end
    def eval_value=(x)
        @value = nil
        @eval_value = x
        self.instance_eval("def get_value;#{@eval_value};end")
        nil
    end
    def call
        result = nil
        if(!@eval_value.nil? && !@eval_value.to_s.nil?)
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
        if(@ctx.include? sym.to_s)
            @ctx[sym.to_s]
        else
            puts "Callable Method Missing on #{sym}"
            puts "unknown context method..."
            puts @ctx
        end
    end

    def to_s()
        "<Callable:#{@value.inspect}-#{@eval_value.inspect}>"
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
        @identifier = id
        @stale = true
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
    #Fully qualified name of property
    attr_accessor :identifier
    #List of known properties which this property reads from
    attr_accessor :depends
    #List of known properties which this property writes to
    attr_accessor :rdepends
    #Boolean property if this data is out-of-date
    attr_accessor :stale
    #Proc Callback for obtaining the new value
    attr_accessor :callback
    #Any value that the current object produces
    attr_accessor :value
    #Container for onXYZ methods
    attr_accessor :onWrite

    def to_s()
        tmp = @stale ? "?" : "XX"
        out = "#<Property:#{self.id}=#{tmp}"
        if(!@depends.empty?)
            out = out+"dep=#{@depends.each{|x|x.id}.join}"
        else
            out = out
        end
        if(callback && callback.eval_value)
            if(callback.eval_value.length < 20)
                out = out+"callback=#{callback.eval_value}>"
            else
                out = out+"callback=#{callback.eval_value[0..20]}>"
            end
        else
            out = out+">"
        end
    end

    def id
        if(@ppath)
            @ppath+@identifier
        else
            "/empty/"+@identifier
        end
    end
end

class PropertyDatabase
    def initialize()
        @transaction_nest = 0
        @read_list = []
        @old_read_list = []
        @plist = []
        @stale_rdep_graph = true
        @read_count = 0
        @needs_update = false
    end

    def try_patch_rdep(prop, ndep)
        if(prop.depends.empty? && !@stale_rdep_graph)
            ndep.each do |dp|
                dp.rdepends << prop
            end
        else
            @stale_rdep_graph = true
        end

    end

    def update_dependency(prop, ndep)
        if(ndep != prop.depends)
            try_patch_rdep(prop, ndep)
        end
        prop.depends = ndep
    end

    def load_property(prop)
        @read_count += 1

        #puts "[DEBUG] Loading #{prop.id} at transaction #{@transaction_nest}"
        #puts "[DEBUG] dependency is #{prop.depends}"
        #puts "[DBBUG] [#{prop.callback.nil?}, #{prop.stale}, #{prop.value}]"

        #Insert dependency information on load
        @read_list << prop if(@transaction_nest != 0)

        #Return quickly if there is no callback or if the property is known to
        #be non-stale
        return prop.value if  prop.callback.nil?
        return prop.value if !prop.stale

        prop.depends.each do |x|
            load_property(x) if x.stale
        end

        oldValue = prop.value

        #puts "[DEBUG] Loading #{prop.id}..." if prop.id.match(/extern/)
        start_load_transaction()
        prop.value = prop.callback.call()
        read_list  = end_load_transaction()

        update_dependency(prop, read_list) if read_list != prop.depends

        if(oldValue != prop.value)
            prop.onWrite.each do |x|
                #puts "[DEBUG] running onWrite callbacks..." if prop.id.match(/extern/)
                x.call
            end
        end

        prop.stale = false

        #puts "[DEBUG]#{prop.identifier}[] = #{prop.value}"
        #puts "[DEBUG]    slow return #{prop.value}" if prop.id.match(/extern/)
        prop.value
    end

    def write_property(p, value)
        #puts "[DEBUG] write property #{p} with #{value}"
        #puts "[DEBUG] rdep = #{p.rdepends.to_a}"
        #Update value and mark dependent properties as stale
        p.callback = nil
        if(p.value != value)
            p.value    = value
            p.onWrite.each do |x|
                x.call
            end
        end
        if(p.stale)
            p.stale = false
        end
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
    end

    def propigate_stale(src)
        return if src.stale
        src.rdepends.each do |prop|
            if(!prop.stale)
                prop.stale = true
                propigate_stale prop
            end
        end
    end

    def connect_property(p, cb, context)
        #t1 = Time.new
        if(cb.is_a? String)
            if(cb[0] == "{")
                cb = "begin\n"+cb[1..-2]+"\nend"
            end
            c = Callable.new(context)
            c.eval_value  = cb
            p.callback    = c
            p.stale       = true
            @needs_update = true
        else
            puts "I don't understand this connection..."
            puts cb.class
            pp cb
            raise Exception.new
        end
        nil
        #puts "connection time is #{1000*(Time.new-t1)}ms"
    end

    def connect_watcher(p, cb, context)
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
            raise Exception.new
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
            out += "\n" + p.to_s
        end
        out + ">"
    end

    def force_update()
        @plist.each do |x|
            x.stale         = true
        end
        update_values
    end

    def update_values()
        @plist.each do |x|
            if(x.callback.nil? || !x.stale)
                next
            end
            load_property x
        end
    end

    attr_accessor :plist

    def reads()
        @read_count
    end

    def add_property(prop)
        @plist << prop
    end

    def remove_properties(del_list)
        del_set = Set.new(del_list)
        next_list = []

        @plist.each do |x|
            next_list << x if !(del_set.include? x)
        end
        @plist = next_list
    end

    attr_reader :needs_update
end
