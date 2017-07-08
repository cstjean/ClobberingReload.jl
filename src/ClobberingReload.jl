__precompile__()

module ClobberingReload

using MacroTools
using MacroTools: postwalk

export creload, creload_strip, creload_diving, apply_code!, revert_code!,
    update_code_revertible, RevertibleCodeUpdate, CodeUpdate, EvalableCode, source

include("fundef.jl") # hopefully temporary
include("scrub_stderr.jl")

function counter(seq)  # could use DataStructures.counter, but it's a big dependency
    di = Dict()
    for x in seq; di[x] = get(di, x, 0) + 1 end
    di
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
    error("ClobberingReload error: Cannot parse $fname; must contain a module. Exception $e")
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
function run_code_in(code::Vector, mod, in_file=nothing)
    if in_file !== nothing
        return withpath(in_file::String) do
            run_code_in(code, mod)
        end
    end
    scrub_redefinition_warnings() do
        eval(get_module(mod), Expr(:toplevel, code...))
    end
end
run_code_in(code::Expr, mod, in_file=nothing) = run_code_in([code], mod, in_file)


""" `creload(mod_name)` reloads `mod_name` by executing the module code inside
the **existing** module. So unlike `reload`, `creload` does not create a new
module objects; it merely clobbers the existing definitions therein. """
function creload(mod)
    mod_name = creload(identity, mod)
    module_was_loaded!(mod_name)  # for areload()
end    
creload(code_function::Function, mod_name::Module) =
    creload(code_function, string(mod_name))

""" `creload(f::Function, mod_name)` applies `f` to the code before reloading it.
This allows external instrumentation of a module's code (for instance, to add profiling
code). `f` accepts a Vector of Expr and should return a Vector of Expr. """
function creload(code_function::Function, mod_name::String)
    info("Reloading $mod_name")
    mod_path = Base.find_in_node_path(mod_name, nothing, 1)
    if mod_path === nothing
        error("Cannot find path of module $mod_name. To be reloadable, the module has to be defined in a file called $mod_name.jl, and that file's directory must be pushed onto the LOAD_PATH")
    end
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

################################################################################

immutable EvalableCode
    code::Vector{Expr}
    mod::Module
    file::Union{String, Void}
end
apply_code!(ec::EvalableCode) = run_code_in(ec.code, ec.mod, ec.file)
Base.length(ec::EvalableCode) = length(ec.code)

immutable CodeUpdate
    ecs::Vector{EvalableCode}
end
Base.merge(cu1::CodeUpdate, cus::CodeUpdate...) =
    # We could conceivably merge the EvalableCode objects that share the same (mod, file)
    CodeUpdate(mapreduce(cu->cu.ecs, vcat, cu1.ecs, cus))
apply_code!(cu::CodeUpdate) = map(apply_code!, cu.ecs)

immutable RevertibleCodeUpdate
    apply::CodeUpdate
    revert::CodeUpdate
end
Base.merge(rcu1::RevertibleCodeUpdate, rcus::RevertibleCodeUpdate...) =
    RevertibleCodeUpdate(merge((rcu.apply for rcu in (rcu1, rcus...))...),
                         merge((rcu.revert for rcu in (rcu1, rcus...))...))
apply_code!(rcu::RevertibleCodeUpdate) = apply_code!(rcu.apply)
revert_code!(rcu::RevertibleCodeUpdate) = apply_code!(rcu.revert)
function (rcu::RevertibleCodeUpdate)(body_fn::Function)
    try
        # It's safer to have the `apply_code!` inside the try, because we should be
        # able to assume that running `revert_code!` is harmless even if apply_code!
        # had an error half-way through.
        apply_code!(rcu)
        @eval $body_fn()   # necessary to @eval because of world age
    finally
        revert_code!(rcu)
    end
end

parse_file_mod(file, mod) = (file == module_definition_file(mod) ?
                             parse_module_file(file)[2] : parse_file(file))

""" `update_code(fn::Function, mod::Module)` applies `fn` to every expression
in every file of the module, and returns a `CodeUpdate` with the result. """
update_code(fn::Function, mod::Module) =
    # Note: this was never used so far - July '17
    CodeUpdate([EvalableCode(map(fn, parse_file_mod(file, mod)), mod, file)
                for file in gather_all_module_files(string(mod))])


""" `update_code_many(fn::Function, mod::Module)` applies `fn` to every expression
in every file of the module, expects a tuple of Expr to be returned, and returns a
corresponding tuple of `CodeUpdate`. """
update_code_many(fn::Function, mod::Module) =
    # TODO: check that the every tuple of the zip transposes have the same length.
    # Note: Tuple(generator) syntax is 0.6-only
    tuple((merge(cus...)
           for cus in zip((update_code_many(fn, mod, file)
                           for file in gather_all_module_files(string(mod)))...))...)

update_code_many(fn::Function, mod::Module, file::String) =
    tuple((CodeUpdate([EvalableCode(Expr[c for c in newcode if c !== nothing],
                                    mod, file)])
           for newcode in zip(map(fn, parse_file_mod(file, mod))...))...)

################################################################################
# These should go into MacroTools/ExprTools

is_function_definition(expr::Expr) = longdef1(expr).head == :function
is_function_definition(::Any) = false

""" `get_function(mod::Module, fundef::Expr)::Function` returns the `Function` which this
`fundef` is defining. This code works only when the Function already exists. """
get_function(mod::Module, fundef::Expr)::Function = eval(mod, splitdef(fundef)[:name])

is_call_definition(fundef) = @capture(splitdef(fundef)[:name], (a_::b_) | (::b_))

################################################################################

function update_code_revertible(fn::Function, mod::Module,
                                args...) # to support specifying which file
    apply, revert = update_code_many(mod, args...) do code
        res = fn(code)
        if res === nothing
            (nothing, nothing)
        else
            (res, code)
        end
    end
    return RevertibleCodeUpdate(apply, revert)
end

function update_code_revertible(new_code_fn::Function, mod::Module,
                                file::String, fn_to_change::Function)
    update_code_revertible(mod, file) do expr
        if (is_function_definition(expr) &&
            !is_call_definition(expr) &&
            get_function(mod, expr) == fn_to_change)
            new_code_fn(expr)
        else nothing end
    end
end

update_code_revertible(new_code_fn::Function, fn_to_change::Function) =
    merge((update_code_revertible(new_code_fn, mod, string(file), fn_to_change) 
           for ((mod, file), count) in counter((m.module, m.file)
                                               for m in methods(fn_to_change).ms))...)

function source(obj::Union{Module, Function})
    code = []
    # It's (negligibly) wasteful and ugly to use `update_code_revertible` when all we
    # want is to get the Module's or the Function's definitions, but I doubt that a
    # refactor would be any cleaner. - June'17
    update_code_revertible(obj) do expr
        push!(code, expr)
        nothing
    end
    code
end

include("autoreload.jl")

end # module
