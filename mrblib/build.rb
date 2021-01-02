#Qml Files can be found via a few different paths
#This global keeps track of where they are searched for
QmlSearchPath = []

$ruby_mode = :MRuby

#Cached Information
##When a qml class is processed it can be cached as a real class
##This avoids incurring the cost of parsing the methods and attribute accessors
##repeatedly
CachedClasses = Set.new
##When qml is loaded the IR is cached
CachedIR      = Hash.new
##Graph dependencies of classes (determines when to regenerate)
CachedDep     = Hash.new
##The qml cache can be invalidated based upon differing c-time
CachedCtime   = nil

#Statistics
##Keep track of the total number of objects created
$total_objs = 0

module Qml
    def self.context_apply(ctx, cls)
        ctx.each do |k,v|
            cls.__send__(k+"=", v) if cls.respond_to?(k+"=")
        end
    end

    def self.add_child(parent, child)
        child.parent = parent
        children = parent.children
        children << child
        parent.children = children
    end

    def self.prop_add(cls, field)
        prop = Property.new(field)
        cls.properties[field] = prop
        cls.db.add_property prop
    end
end

#Print code blocks with corrected indentation
def code_format_print(code)
    indent = 0
    l = 1
    code.each_line do |ln|
        ln = ln.strip
        if(ln.match(/^end/))
            indent -= 4
        end
        indent = 0 if indent < 0
        ll = " "
        if(l<10)
            ll = "00#{l} "
        elsif(l<100)
            ll = "0#{l} "
        else
            ll = "#{l} "
        end
        l += 1

        puts ll + " "*indent + ln

        if(ln.match(/^class/))
            indent += 4
        elsif(ln.match(/^def/))
            indent += 4
        elsif(ln.match(/do$/))
            indent += 4
        end

        if(ln.match(/end$/) && !ln.match(/^end/))
            indent -= 4
        end
    end
end

#Class to populate the CachedClasses global
class QmlIrToRuby

    #Initialize converter
    #ir      - a hash of qml names to qml IR
    #damaged - a collection of IR names which have been altered or nil for a
    #          complete regeneration
    def initialize(ir, damaged=nil, cache_file=nil)
        @ir      = ir
        @class   = nil
        @context = []
        @init    = ""
        @setup   = ""
        @dep     = Hash.new

        build_qml_dep_graph

        tic = Time.new
        @cache_load = []#File.open("/tmp/fcache.rb", "w+")
        ir.each do |k, v|
            if(k[0].upcase == k[0])
                if($damaged_classes.include? k)
                    #t1 = Time.new
                    solve_ir k
                    #t2 = Time.new
                    #puts "#{k} in #{((t2-t1)*1000).to_i} ms"
                end
            end
        end

        if(cache_file)
            file = File.open(cache_file, "w+")
            cc   = nil
            loader = reorder_cache()
            loader.each do |cl|
                type, cls, dat = cl

                #Switching Classes
                if(cc != cls)
                    file.puts("end") if(cc)
                    if(type == :cls_def)
                        file.puts("class Qml::#{cls} < #{dat}")
                    else
                      puts "Innefficient irep waste"
                        file.puts("class Qml::#{cls}")
                    end
                    cc = cls
                end

                #Normal Statements
                if(type == :attr ||
                   type == :method ||
                   type == :reader ||
                   type == :accessor)
                    file.print("  ")
                    file.puts(dat)
                elsif(type == :cls_def)
                    #Do nothing else
                else
                    raise :unhandled
                end
            end

            file.puts("end") if cc
            file.close
        end
        $damaged_classes = []
        toc = Time.new
        puts "Total time is #{1000*(toc-tic)} ms"
    end

    def reorder_cache()
      known_cls = {}
      stream_out = []
      @cache_load.each_with_index do |cl, idx|
        type, cls, dat = cl
        next if(known_cls.include?(cls))
        known_cls[cls] = true

        @cache_load.each do |c|
          stream_out << c if(c[1] == cls)
        end
      end
      return stream_out
    end

    def solve_ir(cls)
        #Push old state onto stack
        old    = @class
        oldi   = @init
        olds   = @setup
        oldcc  = @cc_id
        oldctx = @context
        @class = cls
        ir     = @ir[cls]
        supe   = @dep[cls]
        @init  = ""
        @setup = ""
        @cc_id = 0
        @context = []


        #puts "========================================================================="
        #puts "Solving class = #{cls}"
        #puts "super is #{supe}"
        #puts "========================================================================="
        if(!get_global_const(supe))
            if(!@ir.include? supe)
                puts supe
                raise Exception.new("unknown base class....")
            else
                if(!get_qml_const(supe))
                    solve_ir supe
                end
                supe = "Qml::"+supe
            end
        end
        #puts "solving #{cls}"
        estr = "class Qml::#{cls} < #{supe};end"
        @cache_load << [:cls_def, cls, supe]
        eval(estr)
        #puts "installing context..."
        ctx, use, keys = get_context(ir)
        install_context(ctx, use, keys)
        #puts "processing ir..."
        ir.each do |x|
            consume_instruction x
        end
        #puts "##installing database..."
        install_database
        #puts "##installing initializer..."
        install_initialize(supe)
        #puts "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
        #puts "Done with #{@class}"
        #puts "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"

        #Pop state off stack
        @cc_id = oldcc
        @class = old
        @init  = oldi
        @setup = olds
        @context = oldctx
    end

    def get_qml_const(c)
        Qml.const_get c
    rescue Exception
        nil
    end

    def get_global_const(c)
        Kernel.const_get c
    rescue Exception
        nil
    end

    def consume_instruction(inst)
        #puts "consuming #{inst}"
        case inst[0]
        when SC #ignore
        when CC
            id = inst[3]
            cls = inst[1]
            if(!get_global_const(inst[1]) && !get_qml_const(inst[1]))
                if(@ir.include? inst[1])
                    solve_ir(inst[1])
                else
                    puts inst[1]
                    raise "unknown base class"
                end
            end

            if(get_qml_const(cls))
                cls = "Qml::" + cls
            end

            if(@cc_id == 0)
                @setup += "@#{id} = self\n"
            else
                @setup += "@#{id} = #{cls}.new(database, ui_path+#{@cc_id.to_s.inspect}+'/')\n"
            end
            @cc_id += 1
        when AA
            id = inst[1]
            add_attr(inst, id)
        when AM
            obj = inst[1]
            add_method(inst, obj)
        when SP
            (child, parent) = inst[1..2]
            @init += "Qml::add_child(#{@context[parent]}, #{@context[child]})\n"
        when CA
            obj = inst[1]
            add_attr_connection(inst, obj)
        when CI
            obj = inst[1]
        when EC #ignore
        else
            puts "Unknown Opcode..."
            puts inst
        end
    end

    #Construct the dependencies present between various classes
    def build_qml_dep_graph
        @ir.each do |key, ir|
            #puts "#{key} dep is #{get_dep ir}"
            @dep[key] = get_dep ir
        end
    end

    def get_dep(ir)
        ir.each do |x|
            if(x.type == CC && x[2] == 0)
                return x[1]
            end
        end
        nil
    end

    def map_include(needles, haystack)
        out = []
        needles.each do |n|
            out << haystack.include?(n)
        end
        out
    end

    def map_or!(a,b)
        (0...a.length).each do |i|
            a[i] = a[i] || b[i]
        end
        a
    end

    def print_matrix(m)
        m.each do |mm|
            mm.each do |mmm|
                print "1" if  mmm
                print "0" if !mmm
            end
            puts
        end
    end

    def get_context(ir)
        ctx = Hash.new
        keys = []

        #Identify context fields
        off = 0
        ir.each do |inst|
            if(inst.type == CC && inst.length == 4)# && inst[3] != "anonymous")
                if(off == 0)
                    ctx[inst[3]] = "self"
                    @context[off] = "self"
                else
                    ctx[inst[3]] = "@"+inst[3]
                    @context[off] = "@"+inst[3]
                end
                keys << inst[3]
                off += 1
            end
        end

        use_mtx = []
        n = keys.length
        n.times do
            t = []
            n.times do
                t << false
            end
            use_mtx << t
        end

        #check connect_attr and add_method instructions for context references
        ir.each do |inst|
            #if(inst.type == CA)
            #    id = inst[1]
            #    tmp = map_include(keys, inst.fields[2])
            #    map_or!(use_mtx[id], tmp)
            if(inst.type == AM)
                #puts inst.fields[3]
                id = inst[1]
                tmp = map_include(keys, inst.fields[3])
                map_or!(use_mtx[id], tmp)
            end
        end

        #puts ctx.inspect
        #puts keys.inspect
        #print_matrix(use_mtx)
        return [ctx, use_mtx, keys]
    end

    #Create method
    def add_method(meth, cls)
        if(cls == 0)
            install_method(meth)
        else
            indirect_method(meth, cls)
        end
    end

    #Create properties
    def add_attr(attr, cls)
        if(cls == 0)
            install_attr(attr)
        else
            raise "unimplemented attr"
        end
    end

    Special = ["x", "y", "w", "h", "tooltip", "parent", "bg", "textColor",
               "prev", "valueRef", "dragScale", "vertical", "whenValue",
               "pad", "slidetype", "num", "options", "opt_vals", "selected",
               "layoutOpts", "children", "layer", "whenClick","textScale",
               "renderer", "action", "whenSwapped", "highlight_pos", "topSize",
                "copyable", "editable"]

    Literals = ["nil", "1", "0", "true", "false", "[]", "1.0", "0.5", "0.75",
                "false", "[:ignoreAspect]"]
    def literal?(x)
        if(x[0] != '"' || x[-1] != '"')
            false
        else
            Literals.include?(strip_literal(x))
        end
    end

    def strip_literal(x)
        x[1..-2]
    end

    def pure_string(x)
        return false if x[0] != '"'
        return false if x[-1] != '"'
        x[1..-2].each_char do |i|
            return false unless /[:a-zA-Z 0-9\/]/.match(i)
        end
        true
    end

    def pure_numeric(x)
        x.each_char do |i|
            return false unless /[\.0-9]/.match(i)
        end
        true
    end

    def pure_symbol(x)
        return false if x[0] != ":"
        x[1..-1].each_char do |i|
            return false unless /[a-zA-Z]/.match(i)
        end
        true
    end

    def make_callback(value)
        pr = "lambda {"
        #@context.each do |c|
        #    cc  = c[1..-1]
        #    pr += "#{cc} = #{c}\n" if value.include?(cc)
        #end
        if(value[0] == "{")
            value = "begin\n"+value[1..-2]+"\nend"
        end
        pr += value + "}"
        pr
    end

    #Apply connections of various values
    def add_attr_connection(conn, cls)
        field = conn[2]
        value = conn[3]

        if(cls == 0)
            objs = "self."
        else
            objs = @context[cls]+"."
        end

        val = value.inspect
        tmp = val.gsub("\#{","\\\#{")
        val = tmp if tmp

        if(!field.match(/^on/))
            #Check for simple value cases
            if(literal?(val))
                @init += "#{objs}#{field} = #{strip_literal(val)}\n"
            elsif(val == "\"\\\"\\\"\"" && cls == 0)
                @init += "#{objs}#{field} = \"\"\n"
            elsif(Special.include? field)
                @init += "#{objs}#{field} = #{value}\n"
            elsif(pure_string(value) || pure_numeric(value) || pure_symbol(value))
                @init += "#{objs}#{field} = #{value}\n"
            else
                @init += "@db.connect_property(#{objs}properties[#{field.inspect}], #{make_callback(value)})\n"
            end
        else
            field    = field[2..-1]
            field[0] = field[0].downcase
            @init += "@db.connect_watcher(#{objs}properties[#{field.inspect}], #{make_callback(value)})\n"
        end
    end

    def add_parent(parent, cls)
    end

    #Create class initialize method for the form Class.new(database)
    def install_initialize(sup)
        superargs = "()"
        if(sup[0..4] == "Qml::")
            superargs = "(database, ui_path)"
        end
        inner = "def initialize(database, ui_path=\"/ui/\")
    #t1 = Time.new
    super#{superargs}
    @db         ||= database
    @ui_path      = ui_path
    @properties ||= Hash.new
    #t1 = Time.new
    #{@setup}
    #{@init}
    #puts \"#{@class}, \#{1000000*(Time.new-t1)}, 123456\"
end"
        eval_str = "class Qml::#{@class};#{inner};\nend"
        #code_format_print eval_str if @class == "ZynAddGlobal"
        @cache_load << [:method, @class, inner]
        eval(eval_str, nil, "anonymous-#{@class}", 0);
    end

    #Create accessors for properties, database, and path info
    def install_database
        Qml.const_get(@class).class_eval do
            attr_reader   :properties
            attr_accessor :db, :ui_path
        end
        @cache_load << [:attr, @class, "attr_reader :properties"]
        @cache_load << [:attr, @class, "attr_accessor :db, :ui_path"]
    end

    #Create class method
    def install_method(meth)
        (name, args, code) = meth[2..4]
        @cache_load << [:method, @class, "def #{name}(#{args});#{code};end"]
        eval("class Qml::#{@class}\n def #{name}(#{args});#{code};end\n end", nil, meth.file, meth.line)
    end

    def indirect_method(meth, cls)
        (name, args, code) = meth[2..4]
        code = code.inspect[1..-2]
        #code.gsub!("\#{","\\\#{") #if $ruby_mode != :CRuby
        @init += "
        #{@context[cls]}.instance_eval(\"def #{name}(#{args});#{code};end\", #{meth.file.inspect}, #{meth.line})\n"
        #@init += "print '%'\n"
    end

    #Create id->object mapper
    def install_context(ctx, use, keys)
        #puts "ctx = #{ctx}"
        anon_test = /^anony/
        @init += "\ncontext = Hash.new\n"
        n = keys.length
        (0...n).each do |i|
            k = keys[i]
            v = ctx[k]
            if(!k.inspect.match(/anonymous/))
                @cache_load << [:reader, @class, "attr_reader :#{k}"]
                eval("class Qml::#{@class}\n def #{k};#{v};end\n end")

                @init += "context[#{k.inspect}] = #{v}\n"
            end

            if(v == "self")
                next
            end

            num_fields = 0
            (0...n).each do |j|
                next if(use[i][j] == false)

                if(!(ctx[keys[j]].match anon_test))
                    num_fields += 1
                end
            end

            if(num_fields != 0)
                @init += "#{v}.instance_eval do\n"
                (0...n).each do |j|

                    next if(use[i][j] == false)

                    kk = keys[j]
                    if(kk.match anon_test)
                        next
                    end
                    @init += "def #{kk}=(k);@#{kk}=k;end\n"
                    @init += "def #{kk};    @#{kk};  end\n"
                end
                @init += "end\n"
            end
        end

        (0...n).each do |i|
            k = keys[i]
            v = ctx[k]
            if(v == "self")
               next
            end
            sum = 0
            (0...n).each do |j|
                sum += 1 if use[i][j]
            end

            @init += "Qml::context_apply(context, @#{k})\n" if sum != 0
        end
    end

    #Create attribute reader/writer pairs
    def install_attr(attr)
        #Add reader/writer
        inner = code_attr(attr)
        estr = "class Qml::#{@class}\n #{inner}\n end"
        eval(estr, nil, attr.file, attr.line)
        @cache_load << [:accessor, @class, inner]

        name = attr[2]

        if(!Special.include? name)
            @init += "Qml::prop_add(self, #{name.inspect})\n"
        end
    end



    def indirect_attr(attr,cls)
        "children[#{cls}].instance_eval(\"#{code_attr}\", #{attr.file}, #{attr.line})"
    end

    def code_attr(attr)
        name = attr[2]
        if(Special.include?(name))
            "attr_accessor :#{name}"
        else
            "attr_property :#{name}"
        end
    end
end

class Module
    def attr_property(property)
        pstring = property.to_s

        define_method property do
            prop = @properties[pstring]
            tmp  = @db.load_property(prop)
        end
        define_method "#{pstring}=" do |new_value|
            prop = @properties[pstring]
            @db.write_property(prop,new_value);

            #Inline loop
            ind      = 0
            on_write = prop.onWrite
            n        = on_write.length
            while(ind < n)
                on_write[ind].call
                ind += 1
            end
        end
    end
end


#Test Code
$test_counter = 0
$test_err = 0
$test_quiet = false
def assert_eq(a,b,str)
    $test_counter += 1
    err = a!=b
    if(err)
        puts "not ok #{$test_counter} - #{str}..."
        puts "# Expected #{a.inspect}, but observed #{b.inspect} instead"
        $test_err += 1
    else
        puts "ok #{$test_counter} - #{str}..." unless $test_quiet
    end
    err
end

def assert_not_eq(a,b,str)
    $test_counter += 1
    err = (a==b);
    if(err)
        puts "not ok #{$test_counter} - #{str}..."
        puts "# Expected not #{a.inspect}, but observed #{b.inspect} instead"
        $test_err += 1
    else
        puts "ok #{$test_counter} - #{str}..." unless $test_quiet
    end
    err
end

def assert_not_nil(a,str)
    $test_counter += 1
    err = a.nil?
    if(err)
        puts "not ok #{$test_counter} - #{str}..."
        puts "# Observed unexpected nil instead"
        $test_err += 1
    else
        puts "ok #{$test_counter} - #{str}..." unless $test_quiet
    end
    err
end

def assert_nil(a,str)
    $test_counter += 1
    err = !a.nil?
    if(err)
        puts "not ok #{$test_counter} - #{str}..."
        puts "# Expected nil, but observed #{a} instead"
        $test_err += 1
    else
        puts "ok #{$test_counter} - #{str}..." unless $test_quiet
    end
    err
end

def test_summary
    puts "# #{$test_err} test(s) failed out of #{$test_counter} (currently passing #{100.0-$test_err*100.0/$test_counter}% tests)" unless $test_quiet
end

def doTest
    QmlIrToRuby.new(loadIR)
    puts "done..."

    db  = PropertyDatabase.new
    t1 = Time.new
    tb = Qml::TestBase.new(db)
    t2 = Time.new

    db.force_update

    #puts db.to_s
    puts "time to create is #{1000000*(t2-t1)}us"
    assert_not_nil(tb,    "Allocated TestBase is non-nil")
    assert_not_nil(tb.tb, "A reference to self is available based upon the id")
    assert_nil(tb.p1,     "A property is initialized to the appropriate value")
    assert_nil(tb.p3,     "A chained property is initialized to the appropriate value")
    assert_nil(tb.p2,     "A chained property is initialized to the appropriate value")

    tb.p1 = 1
    db.force_update
    assert_not_nil(tb.p1, "A property is updated to the appropriate value")
    assert_not_nil(tb.p2, "A chained property is updated to the appropriate value")
    assert_not_nil(tb.p3, "A chained property is updated to the appropriate value")
    #exit
    #puts db.to_s

    t1 = Time.new
    #te = nil
    #(0..1000).each do |x|
    te = Qml::TestExt.new(db)
    #end
    t2 = Time.new
    puts "time to create is #{1000000*(t2-t1)}us"
    assert_not_nil(te,    "Extended classes are non-nil")
    assert_not_eq(te.te1, te.te2, "Children are different instances 1/2")
    assert_not_eq(te.te2, te.te3, "Children are different instances 2/2")

    assert_eq(3, te.children.length, "Children are assigned to their parent")

    assert_nil(te.te3.p1,   "Unchanged properties use defaults")
    assert_eq(5, te.te3.p2, "Changed parameters update")
    assert_eq(5, te.te3.p3, "Changed parameters update using dependency graph")

    assert_nil(te.te4.p1,   "Proxy Objects are provided to children")

    #puts te.to_s
    db.force_update
    test_summary


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
    #mw
end

def testSetup(widg)
    if(widg.respond_to? :onSetup)
        widg.onSetup(nil)
    end
    n = widg.children.length
    (0...n).each do |i|
        testSetup(widg.children[i])
    end
end

#Load new classes if there are changes in files which should be hot loaded
#Hotloading is activated if workaround=false.
def doFastLoad(search=nil, workaround=true)
    t1 = Time.new
    db  = PropertyDatabase.new
    lir = workaround || loadIR(search)
    if(lir)
        t2 = Time.new
        workaround || QmlIrToRuby.new(lir)
        t3 = Time.new
        mw  = Qml::MainWindow.new(db)
        #mw  = Qml::ZynResOptions.new(db)
        t4 = Time.new
        puts "Time for a fast load is #{1000*(t4-t1)}ms load(#{1000*(t2-t1)}) class(#{1000*(t3-t2)}) spawn(#{1000*(t4-t3)})..."
        db.force_update
        #puts db
        return mw
    else
        return nil
    end
    #TODO make this rescue only capture missing file issues
rescue Exception=>e
    puts e
    e.backtrace.each do |ln|
        puts ln
    end
    nil
end

QmlIRCache = nil

def get_qml_const(c)
    Qml.const_get c
rescue Exception
    nil
end

def createInstance(name, parent, pdb)
    if(get_qml_const(name))
        #puts "createInstance from cached class <#{name}>..."
        children = parent.children
        npath = "#{parent.ui_path}#{children.length+1}/"

        child = get_qml_const(name).new(db, npath)

        children << child
        parent.children = children
        child
    else
        puts "SSSSSSSSSSSSSSLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLOOOOOOOOOOOOOOOOOOOOOOOOOWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
        qml_ir = QmlIRCache
        ir     = qml_ir[name]
        pbvm   = ProgBuildVM.new(ir, qml_ir, pdb)
        child  = pbvm.instance

        #TODO fix hackyness here with UI paths
        children = parent.children
        children << child
        parent.children = children
        npath = "#{parent.ui_path}#{children.length}/"
        child.ui_path = npath
        child.properties.each do |key,p|
            p.ppath = npath
        end

        child
    end
end

module GL
    class PUGL
        attr_accessor :w, :h
    end
end
