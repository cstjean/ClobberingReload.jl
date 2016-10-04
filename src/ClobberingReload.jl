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
function creload(mod_name)
    info("Reloading $mod_name")
    mod_path = Base.find_in_node_path(mod_name, nothing, 1)
    withpath(mod_path) do
        # real_mod_name is in case that the module name differs from the
        # file name, but... I'm not sure that makes any difference. Maybe we
        # should just assert that they're the same.
        real_mod_name, code = parse_module_file(mod_path)
        scrub_redefinition_warnings() do
            eval(eval(Main, real_mod_name), Expr(:toplevel, code...))
        end

        # For areload()
        module_was_loaded!(mod_name)
    end
end

include("autoreload.jl")

end # module
