module ClobberingReload

using MacroTools

export creload

""" `parse_module_file(fname)` parses the file named `fname` as a module file
(i.e. `module X ... end`) and returns `(module_name, code::Vector)`. """
function parse_module_file(fname::String)
    code = parse_file(fname)
    doc_mac = GlobalRef(Core, Symbol("@doc"))  # @doc head
    for expr in code
        # Skip the docstring. It's unfortunate that MacroTools doesn't seem
        # to work here.
        if isa(expr, Expr) && expr.head==:macrocall && expr.args[1] == doc_mac
            expr = expr.args[3]
        end
        if (@capture expr module modname_ code__ end)
            return modname, code
        end
    end
    error("ClobberingReload error: Cannot parse $fname; must contain a module. Exception $e")
end

""" `parse_file(filename)` returns the expressions in `filename` as a
`Vector` of expressions """
function parse_file(filename)
    str = readstring(filename)
    exprs = Any[]
    pos = 1
    while pos <= endof(str)
        ex, pos = parse(str, pos)
        push!(exprs, ex)
    end
    return exprs
end
## function parse_file(filename)
##     # From Autoreload.jl
##     source = string("begin\n", open(filename) do f; readstring(f) end, "\n end")
##     parsed = parse(source)
##     @assert(@capture parsed begin code__ end)
##     return code
## end

gather_includes(code::Vector) = 
    mapreduce(expr->(@match expr begin
        include(fname_) => [fname]
        any_ => []
    end), vcat, vcat(code, [:(1+1)]))

"""    gather_all_module_files(mod_name::String)

Given a module name (as a string), returns the list of all files that define
this module (i.e. the module name + all included files, applied recursively)
"""
function gather_all_module_files(mod_name::String)
    mod_path = Base.find_in_node_path(mod_name, nothing, 1)
    included_files = Set{String}([mod_path]) # to be filled
    gather(full_path, parse_fun) = 
        cd(dirname(full_path)) do
            mod_includes = map(abspath,
                               gather_includes(parse_fun(basename(full_path))))
        end
    function rec(path::String)
        if !(path in included_files)
            push!(included_files, path)
            map(rec, gather(path, parse_file))
        end
    end
    map(rec, gather(mod_path, mod->parse_module_file(mod)[2]))
    return included_files
end

""" `creload(mod_name)` reloads `mod_name` by executing the module code inside
the **existing** module. So unlike `reload`, `creload` does not create a new
module objects; it merely clobbers the existing definitions therein. """
function creload(mod_name)
    info("Reloading $mod_name")
    mod_path = Base.find_in_node_path(mod_name, nothing, 1)
    cd(dirname(mod_path)) do
        real_mod_name, code = parse_module_file(basename(mod_path))
        eval(eval(Main, real_mod_name), :(begin $(code...) end));

        # For areload()
        module_was_loaded!(mod_name)
    end
end

include("autoreload.jl")

end # module
