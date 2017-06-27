__precompile__()

module ClobberingReload

using MacroTools

export creload

include("scrub_stderr.jl")

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

""" `parse_module_file(fname)` parses the file named `fname` as a module file
(i.e. `module X ... end`) and returns `(module_name, module_code::Vector)`. """
function parse_module_file(fname::String)
    file_code = parse_file(fname)
    doc_mac = GlobalRef(Core, Symbol("@doc"))  # @doc head
    for expr in file_code
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

is_typealias(expr) =
    @capture(expr, (some_type_{params__} = any_) | (const some_type_{params__} = any_))

strip_parametric_typealiases(code) = filter(x->!is_typealias(x), code)

# Taken from CodeTools, see ClobberingReload#3. We could REQUIRE it. It has a
# few dependencies.
function withpath(f, path)
  tls = task_local_storage()
  hassource = haskey(tls, :SOURCE_PATH)
  hassource && (path′ = tls[:SOURCE_PATH])
  tls[:SOURCE_PATH] = path
  try
    return f()
  finally
    hassource ?
      (tls[:SOURCE_PATH] = path′) :
      delete!(tls, :SOURCE_PATH)
  end
end

""" `creload(mod_name)` reloads `mod_name` by executing the module code inside
the **existing** module. So unlike `reload`, `creload` does not create a new
module objects; it merely clobbers the existing definitions therein. """
function creload(mod_name::String)
    info("Reloading $mod_name")
    mod_path = Base.find_in_node_path(mod_name, nothing, 1)
    if mod_path === nothing
        error("Cannot find path of module $mod_name. To be reloadable, the module has to be defined in a file called $mod_name.jl, and that file's directory must be pushed onto the LOAD_PATH")
    end
    withpath(mod_path::String) do
        # real_mod_name is in case that the module name differs from the
        # file name, but... I'm not sure that makes any difference. Maybe we
        # should just assert that they're the same.
        real_mod_name, raw_code = parse_module_file(mod_path)
        code = strip_parametric_typealiases(raw_code)
        scrub_redefinition_warnings() do
            eval(eval(Main, real_mod_name), Expr(:toplevel, code...))
        end
        module_was_loaded!(mod_name)  # for areload()
    end
    mod_name
end
creload(mod::Module) = creload(string(mod))

include("autoreload.jl")

end # module
