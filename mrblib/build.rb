#Qml Files can be found via a few different paths
#This global keeps track of where they are searched for
QmlSearchPath = []

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
end

def code_format_print(code)
    indent = 0
    l = 1
    code.each_line do |ln|
        ln = ln.strip
        if(ln.match(/^end/))
            indent -= 4
        end
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
    end
end

#Class to populate the CachedClasses global
class QmlIrToRuby
    #Initialize converter
    #ir      - a hash of qml names to qml IR
    #damaged - a collection of IR names which have been altered or nil for a
    #          complete regeneration
    def initialize(ir, damaged=nil)
        @ir      = ir
        @class   = nil
        @context = []
        @init    = ""
        @setup   = ""
        @dep     = Hash.new

        build_qml_dep_graph

        tic = Time.new
        #solve_ir "FancyButton"
        #solve_ir "TestBase"
        #solve_ir "TestExt"
        #solve_ir "Knob"
        #solve_ir "ZynLFO"
        ir.each do |k, v|
            if(k[0].upcase == k[0])
                if($damaged_classes.include? k)
                    solve_ir k
                end
            end
        end
        $damaged_classes = []
        toc = Time.new
        puts "Total time is #{1000*(toc-tic)} ms"
    end

    def solve_ir(cls)
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
                raise Exception.new("unknown base class....")
            else
                if(!get_qml_const(supe))
                    solve_ir supe
                end
                supe = "Qml::"+supe
            end
        end
        eval("class Qml::#{cls} < #{supe};end")
        #puts "installing context..."
        install_context(get_context(ir))
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
            #puts "Adding attribute..."
            add_attr(inst, id)
        when AM
            #puts "Adding Function..."
            obj = inst[1]
            add_method(inst, obj)
        when SP
            (child, parent) = inst[1..2]
            @init += "children = #{@context[parent]}.children
            children << #{@context[child]}
            #{@context[parent]}.children = children\n"
        when CA
            obj = inst[1]
            add_attr_connection(inst, obj)
        when CI
            obj = inst[1]
            #puts "Ignoring..."
        when EC
            #puts "Ignoring..."
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

    def get_context ir
        ctx = Hash.new
        off = 0
        ir.each do |inst|
            if(inst.type == CC && inst.length == 4)# && inst[3] != "anonymous")
                if(off == 0)
                    ctx[inst[3]] = "self"#inst[1]
                    @context[off] = "self"
                else
                    ctx[inst[3]] = "@"+inst[3]#inst[1]
                    @context[off] = "@"+inst[3]
                end
                off += 1
            end
        end
        ctx
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

    #Apply connections of various values
    def add_attr_connection(conn, cls)
        field = conn[2]
        value = conn[3]

        if(cls == 0)
            objs = "@"
        else
            objs = @context[cls]+"."
        end

        val = value.inspect
        val.gsub!("\#{","\\\#{")

        if(!field.match(/^on/))
            @init += "@db.connect_property(#{objs}properties[#{field.inspect}], #{val}, context)\n"
        else
            field    = field[2..-1]
            field[0] = field[0].downcase
            @init += "@db.connect_watcher(#{objs}properties[#{field.inspect}], #{val}, context)\n"
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
        eval_str =
        "class Qml::#{@class}
             def initialize(database, ui_path=\"/ui/\")
             super#{superargs}
            @db         ||= database
            @ui_path      = ui_path
            @properties ||= Hash.new
             " + @setup + "#t1 = Time.new\n" + @init + "\n#puts \"Init #{@class} took \#{1000*(Time.new-t1)} ms\"\nend\nend"
        #code_format_print eval_str
        eval(eval_str, nil, "anonymous-#{@class}", 0);
    end

    #Create accessors for properties, database, and path info
    def install_database
        Qml.const_get(@class).class_eval do
            attr_reader   :properties
            attr_accessor :db, :ui_path
        end
    end

    #Create class method
    def install_method(meth)
        (name, args, code) = meth[2..4]
        eval("class Qml::#{@class}\n def #{name}(#{args});#{code};end\n end", nil, meth.file, meth.line)
    end

    def indirect_method(meth, cls)
        (name, args, code) = meth[2..4]
        code = code.inspect[1..-2]
        code.gsub!("\#{","\\\#{")
        @init += "
        #{@context[cls]}.instance_eval(\"def #{name}(#{args});#{code};end\", #{meth.file.inspect}, #{meth.line})\n"
    end

    #Create id->object mapper
    def install_context ctx
        #puts "ctx = #{ctx}"
        anon_test = /^anony/
        @init += "\ncontext = Hash.new\n"
        ctx.each do |k,v|
            eval("class Qml::#{@class}\n def #{k};#{v};end\n end")
            @init += "context[#{k.inspect}] = #{v}\n"

            if(v == "self")
                next
            end

            @init += "#{v}.instance_eval do\n"
            ctx.each do |kk,vv|
                if(kk.match anon_test)
                    next
                end
                @init += "def #{kk}=(k)
                @#{kk}=k
                end
                def #{kk}
                @#{kk}
                end\n"
            end
            @init += "end\n"
        end

        ctx.each do |k,v|
            if(v == "self")
               next
            end
            ctx.each do |kk,vv|
                if(!kk.match anon_test)
                    @init += "#{k}.#{kk} = #{vv}\n"
                end
            end
        end
    end

    #Create attribute reader/writer pairs
    def install_attr(attr)
        #Add reader/writer
        eval("class Qml::#{@class}\n #{code_attr(attr)}\n end", nil, attr.file, attr.line)

        name = attr[2]

        @init += "
        prop = Property.new(#{name.inspect})
        @properties[#{name.inspect}] = prop
        @db.add_property prop
        "
    end



    def indirect_attr(attr,cls)
        "children[#{cls}].instance_eval(\"#{code_attr}\", #{attr.file}, #{attr.line})"
    end

    def code_attr(attr)
        name = attr[2]
        "
        def #{name}
            prop = @properties[\"#{name}\"]
            @db.load_property(prop);
        end

        def #{name}=(val)
            prop = @properties[\"#{name}\"]
            @db.write_property(prop,val);
            prop.onWrite.each do |cb|
                cb.call
            end
        end
        "
    end


end


#Test Code
$test_counter = 0
$test_err = 0
def assert_eq(a,b,str)
    $test_counter += 1
    err = a!=b
    if(err)
        puts "not ok #{$test_counter} - #{str}..."
        puts "# Expected #{a.inspect}, but observed #{b.inspect} instead"
        $test_err += 1
    else
        puts "ok #{$test_counter} - #{str}..."
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
        puts "ok #{$test_counter} - #{str}..."
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
        puts "ok #{$test_counter} - #{str}..."
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
        puts "ok #{$test_counter} - #{str}..."
    end
    err
end

def test_summary
    puts "# #{$test_err} test(s) failed out of #{$test_counter} (currently passing #{100.0-$test_err*100.0/$test_counter}% tests)"
end

def doTest
    db  = PropertyDatabase.new
    QmlIrToRuby.new(loadIR)
    puts "done..."

    t1 = Time.new
    tb = Qml::TestBase.new(db)
    t2 = Time.new
    puts "time to create is #{1000*(t2-t1)}ms"
    assert_not_nil(tb,    "Allocated TestBase is non-nil")
    assert_not_nil(tb.tb, "A reference to self is available based upon the id")
    assert_nil(tb.p1,     "A property is initialized to the appropriate value")
    assert_nil(tb.p3,     "A chained property is initialized to the appropriate value")
    assert_nil(tb.p2,     "A chained property is initialized to the appropriate value")

    t1 = Time.new
    #(0..1000).each do |x|
    te = Qml::TestExt.new(db)
    #end
    t2 = Time.new
    puts "time to create is #{1000*(t2-t1)}ms"
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

    t1 = Time.new
    mw = Qml::MainWindow.new(db)
    t2 = Time.new
    puts "time to create is #{1000*(t2-t1)}ms"

    mw
end

def doFastLoad
    t1 = Time.new
    db  = PropertyDatabase.new
    lir = loadIR
    if(lir)
        #puts "doing load..."
        t2 = Time.new
        QmlIrToRuby.new(lir)
        t3 = Time.new
        mw  = Qml::MainWindow.new(db)
        t4 = Time.new
        puts "Time for a fast load is #{1000*(t4-t1)}ms load(#{1000*(t2-t1)}) class(#{1000*(t3-t2)}) spawn(#{1000*(t4-t3)})..."
        db.force_update
        #puts db
        return mw
    else
        #puts "skipping load..."
        return nil
    end
    #TODO make this rescue only capture missing file issues
rescue
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
