require 'optparse'
require 'ostruct'
require 'set'
require 'yaml'
require 'pp'


#Modifies mapa s.t. it includes the mapb info
def merge_maps(mapa, mapb)
    if mapb
        mapb.each do |key, val|
            if(mapa.has_key?(key) && mapa[key].is_a?(Array))
                mapa[key].concat val
            else
                mapa[key] = val
            end
        end
    end
end


options = OpenStruct.new
options.whitelist = []
options.blacklist = []
options.unmangled = OpenStruct.new
options.unmangled.whitelist = []
options.unmangled.blacklist = []
options.root = "./"
options.dir  = []
options.recursive = false

OptionParser.new do |opts|
      opts.banner = "Usage: example.rb [options] FILES"

      opts.on("-w", "--whitelist FILE",
              "Define a Mangled Whitelist File") do |list|
          options.whitelist << list
      end

      opts.on("-b", "--blacklist FILE",
              "Define a Mangled Blacklist File") do |list|
          options.blacklist << list
      end

      opts.on("-r", "--recursive DIR",
              "Enable Recursive Search Mode") do |dir|
          options.recursive = true
          options.root = dir
      end
end.parse!

white_list = []
options.whitelist.each do |x|
    xxx = File.read(x).split
    white_list.concat xxx
end

#If there are unmangled files, then mangle them and add them to the end of the
#mangled lists

#For each one of the bitcode files, run the pass based preprocessor
files = []
if(!ARGV.empty?)
    files.concat ARGV
end
if(options.recursive)
    files.concat `find #{options.root} -type f | grep -e "\\.bc$"`.split
end

if(files.empty?)
    puts "There Are No Files To Process"
    exit 1
end

#p files
callgraph = Hash.new
function_props = Hash.new
class_high = Hash.new
vtable_information = Hash.new

files.each do |f|
    p "running #{f} file..."
    `opt -load ./src/libfoo.so --dummy1 < #{f} > /dev/null 2> sfpv_output.txt`
    #puts File.read("sfpv_output.txt")
    ncallgraph = YAML.load_file "sfpv_output.txt"


    `opt -load ./src/libfoo.so --dummy2 < #{f} > /dev/null 2> sfpv_output.txt`
    #puts File.read("sfpv_output.txt")
    nfunc = YAML.load_file "sfpv_output.txt"

    `opt -load ./src/libfoo.so --dummy3 < #{f} > /dev/null 2> sfpv_output.txt`
    class_nhigh = YAML.load_file "sfpv_output.txt"

    `opt -load ./src/libfoo.so --dummy4 < #{f} > /dev/null 2> sfpv_output.txt`
    vtable_ninformation = YAML.load_file "sfpv_output.txt"

    merge_maps(callgraph, ncallgraph)
    merge_maps(function_props, nfunc)
    merge_maps(class_high, class_nhigh)
    merge_maps(vtable_information, vtable_ninformation)
end

symbol_list = Set.new
callgraph.each do |key,val|
    symbol_list << key
    val.each do |x|
        symbol_list << x
    end
    val = val.uniq
end

puts "Demangling #{symbol_list.length} Symbols..."
f = File.new("tmp_thing.txt", "w")
f.write(symbol_list.to_a.join("\n"))
f.close
demangled_list = `cat tmp_thing.txt | c++filt`.split("\n")
demangled_symbols = Hash.new
#puts "Resulting in #{demangled_list.length} Items..."
tmp = 0
symbol_list.each do |x|
    demangled_symbols[x] = demangled_list[tmp]
    tmp = tmp + 1
end

demangled_short = Hash.new
demangled_symbols.each do |key, value|
    m = /(\S+)\(/.match(value)
    if(m)
        #puts "#{value} -> #{m[1]}"
        demangled_short[key] = m[1]
    else
        demangled_short[key] = value
    end
end

#pp demangled_short


reason_user_w  = "The Function Was Declared Realtime By A Whitelist"
reason_user_b  = "The Function Was Declared NonRealtime By A Blacklist"
reason_code_w  = "The Function Was Declared Realtime By A Code Annotation"
reason_code_b  = "The Function Was Declared NonRealtime By A Code Annotation"
reason_deduced = "The Function Was Deduced To Need To Be RealTime As It Was Called By A Realtime Function"
reason_none    = "Nom Deduction has occured"
reason_nocode  = "No Code Or Annotations, So The Function is Assumed Unsafe"

class DeductionChain
    attr_accessor :deduction_source, :reason, :realtime_p, :non_realtime_p, :has_body_p, :contradicted_p, :contradicted_by


    def initialize
        @deduction_source = nil
        @reason           = "No Deduction has occured"
        @realtime_p       = false
        @non_realtime_p   = false
        @has_body_p       = false
        @contradicted_p   = false
        @contradicted_by  = Set.new
    end
end

property_list = Hash.new
symbol_list.each do |x|
    property_list[x] = DeductionChain.new
end

puts "Doing Property List Stuff"

#Add information about finding source
callgraph2 = Hash.new
callgraph.each do |key,value|
    property_list[key].has_body_p = true
    if(!value.include? "nil")
        callgraph2[key] = value
    end
end
callgraph = callgraph2

#Add Anything That's On the function_props list
function_props.each do |key, value|
    if(property_list.include? key)
        if(value.include? 'realtime')
            property_list[key].realtime_p = true
            property_list[key].reason     = reason_code_w
        elsif(value.include? 'non-realtime')
            property_list[key].non_realtime_p = true
            property_list[key].reason         = reason_code_b
        end
    end
end

#Add WhiteList information
property_list.each do |key, value|
    if(!value.realtime_p &&
       !value.non_realtime_p)
        if(white_list.include?(key) || white_list.include?(demangled_short[key]))
            value.realtime_p = true
        end
    end
end

#Add Any Known Virtual Calls
vtable_information.each do |key, value|
    value.each do |key2, value2|
        if(value2 != "(none)" && value2 != "__cxa_pure_virtual")
            new_key = "class.#{key}#{key2}"
            if(!callgraph.include? new_key)
                callgraph[new_key] = []
            end
            callgraph[new_key] << value2
            if(!property_list.include? new_key)
                property_list[new_key] = DeductionChain.new
                symbol_list << new_key
            end
            if(!property_list.include? value2)
                property_list[value2] = DeductionChain.new
                symbol_list << value2
            end
            property_list[new_key].has_body_p = true
        end
    end
end

#Add Calls Down the hierarchy [THIS IS BUGGED XXX]
class_high.each do |sub, supers|
    supers.each do |super_|
        50.times do |x|
            testing = "class.#{super_}#{x}"
            source = "class.#{sub}#{x}"
            if(symbol_list.include? testing)
                callgraph[testing] ||= []
                callgraph[testing] << source
                symbol_list << source
                if(!property_list.include? source)
                    property_list[source] = DeductionChain.new
                    property_list[source].has_body_p = true
                end
                property_list[testing].has_body_p = true
            end
        end
    end
end

#Add C++ABI Destructor/Constructor Chaining
symbol_list.each do |sym|
    if /D1Ev$/.match sym
        sym_mod = sym.gsub(/D1Ev$/, "D2Ev")
        if(symbol_list.include?(sym_mod) && !callgraph.include?(sym))
            callgraph[sym] = [sym_mod]
            property_list[sym].has_body_p = true
        end
    end
end

symbol_list.each do |sym|
    if /C1E/.match sym
        sym_mod = sym.gsub(/C1E/, "C2E")
        if(symbol_list.include?(sym_mod) && !callgraph.include?(sym))
            callgraph[sym] = [sym_mod]
            property_list[sym].has_body_p = true
        end
    end
end



#Add no source stuff
property_list.each do |key, value|
    if(!value.has_body_p && !value.realtime_p && !value.non_realtime_p)
        value.non_realtime_p = true
        value.reason         = reason_nocode
    end
end

#Perform Deductions
do_stuff = true
while do_stuff
    do_stuff = false
    property_list.each do |key, value|
        if(!value.contradicted_p)
            if(value.realtime_p() && callgraph.include?(key))
                callgraph[key].each do |x|
                    if(property_list[x].non_realtime_p)
                        value.contradicted_p = true
                        value.contradicted_by << x
                        do_stuff = true
                    elsif(!property_list[x].realtime_p)
                        property_list[x].realtime_p = true
                        property_list[x].deduction_source = key
                        property_list[x].reason = reason_deduced
                        do_stuff = true
                    end
                end
            end
        end
    end
end



#Regenerate Demangled Symbols
demangled_list = `cat tmp_thing.txt | c++filt`.split("\n")
demangled_symbols = Hash.new

tmp = 0
symbol_list.each do |x|
    demangled_symbols[x] = demangled_list[tmp]
    tmp = tmp + 1
end

demangled_short = Hash.new
demangled_symbols.each do |key, value|
    m = /(\S+)\(/.match(value)
    if(m)
        #puts "#{value} -> #{m[1]}"
        demangled_short[key] = m[1]
    else
        demangled_short[key] = value
    end
end

error_count = 0
property_list.each do |key, value|
    if(value.contradicted_p)
        error_count = error_count+1
        pp demangled_symbols[key]
        pp value
        puts "The Contradiction Reasons: "
        value.contradicted_by.each do |x|
            puts " - #{demangled_symbols[x]} : #{property_list[x].reason}"
        end
        puts "\n\n\n"
    end
end

puts "Total of #{error_count} error(s)"

require "graphviz"
g = GraphViz::new( "G" )
color_nodes = Hash.new
property_list.each do |key,val|
    if(val.contradicted_p)
        color_nodes[key] ||= "red"
        val.contradicted_by.each do |x|
            color_nodes[x] = "black"
        end
    elsif(val.realtime_p)
        color_nodes[key] ||= "green"
    end
end


node_list = Hash.new
color_nodes.each do |key,val|
    if(demangled_short.include?(key) && demangled_short[key] && demangled_short[key].length != 0)
        node_list[key] = g.add_node(demangled_short[key], "color"=> val)
    end
end

callgraph.each do |src, dests|
    dests.uniq.each do |dest|
        if(node_list.include?(src) && node_list.include?(dest))
            g.add_edges(node_list[src], node_list[dest])
        end
    end
end
g.output( :png => "sfpv_graphics.png" )
