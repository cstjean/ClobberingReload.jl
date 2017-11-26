__precompile__()

module ClobberingReload

using MacroTools
using MacroTools: postwalk

export creload, creload_strip

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
    for expr in exprs
        if isa(expr, Expr)
            add_filename!(expr, Symbol(filename))
        end
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
    error("ClobberingReload error: Cannot parse $fname; must contain a module.")
end

is_typealias(expr) =
    @capture(expr, (some_type_{params__} = any_) | (const some_type_{params__} = any_) |
             (@compat some_type_{params__} = any_))

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

get_module(mod_name::Symbol) = eval(Main, mod_name)
get_module(mod::Module) = mod

""" `run_code_in(code::Vector, mod, in_file=nothing)` executes `code` as if it was defined
in module `mod`, in file `in_file`. """
run_code_in(code::Vector, mod, in_file=nothing) =
    # [eval(code) for code in exprs] and eval(Expr(:toplevel, exprs...))
    # are both 5X slower than eval(quote $(exprs...) end) as of 0.6 (tested on PyCall)
    run_code_in(quote $(code...) end, mod, in_file)
    
function run_code_in(code::Expr, mod, in_file=nothing)
    if in_file !== nothing
        return withpath(in_file::String) do
            run_code_in(code, mod)
        end
    end
    scrub_redefinition_warnings() do
        eval(get_module(mod), code)
    end
end

""" `creload(mod_name)` reloads `mod_name` by executing the module code inside
the **existing** module. So unlike `reload`, `creload` does not create a new
module objects; it merely clobbers the existing definitions therein. """
function creload(mod)
    mod_name = creload(identity, mod)
    module_was_loaded!(mod_name)  # for areload()
end    

""" `creload(f::Function, mod_name)` applies `f` to the code before reloading it.
This allows external instrumentation of a module's code (for instance, to add profiling
code). `f` accepts a Vector of Expr and should return a Vector of Expr. """
function creload(code_function::Function, mod_name)
    info("Reloading $mod_name")
    mod_path = module_definition_file(mod_name)
    withpath(mod_path::String) do
        # real_mod_name is in case that the module name differs from the file name,
        # but... I'm not sure that makes any difference. Maybe we should just assert
        # that they're the same.
        real_mod_name, raw_code = parse_module_file(mod_path)
        transformed_code = code_function(raw_code)
        run_code_in(transformed_code, real_mod_name)
    end
    mod_name
end

""" `creload_strip(mod)` is like `creload(mod)`, but it strips out the parametric
typealiases (which cause issues under 0.6) """
function creload_strip(mod)
    mod_name = creload_diving(strip_parametric_typealiases, mod)
    module_was_loaded!(mod_name)
end

function insert_include_transform(fun::Function, code::Vector)
    map(code) do expr
        postwalk(expr) do x
            @capture(x, include(file_)) || return x
            :($ClobberingReload.include_transform($file, $fun))
        end
    end
end

""" `include_transform(file::String, fun::Function)` applies `fun` to the parsed code,
then runs it (as in a normal `include`) """
function include_transform(file::String, fun::Function)
    code = parse_file(file)
    run_code_in(fun(code), current_module(), file)
end

diving_transformer(code_function) =
    code -> insert_include_transform(diving_transformer(code_function),
                                     code_function(code))

""" `creload_diving(code_function::Function, mod_name)` will apply `code_function`
to the module's code (as a vector), and to every included file. """
creload_diving(code_function::Function, mod_name) =
    creload(diving_transformer(code_function), mod_name)

################################################################################
# From Tim Holy's Revise.jl
# https://github.com/timholy/Revise.jl/blob/master/src/Revise.jl

function add_filename!(ex::Expr, file::Symbol)
    if ex.head == :line
        ex.args[2] = file
    else
        for (i, a) in enumerate(ex.args)
            if isa(a, Expr)
                add_filename!(a::Expr, file)
            elseif isa(a, LineNumberNode)
                ex.args[i] = add_filename(a::LineNumberNode, file)
            end
        end
    end
    ex
end
if VERSION < v"0.7.0-DEV.328"
    add_filename(lnn::LineNumberNode, file::Symbol) = lnn
else
    add_filename(lnn::LineNumberNode, file::Symbol) = LineNumberNode(lnn.line, file)
end

include("autoreload.jl")

end # module
