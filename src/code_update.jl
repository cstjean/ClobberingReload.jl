export apply_code!, revert_code!, update_code_revertible, RevertibleCodeUpdate,
    CodeUpdate, EvalableCode, source

function counter(seq)  # could use DataStructures.counter, but it's a big dependency
    di = Dict()
    for x in seq; di[x] = get(di, x, 0) + 1 end
    di
end

""" `EvalableCode(code::Vector, mod::Module, fille::Union{String, Void})` contains
code to be evaluated in the context of that `file`, in that module. """
immutable EvalableCode
    code::Vector{Expr}
    mod::Module
    file::Union{String, Void}
end
EvalableCode(code::Expr, mod::Module, file) = EvalableCode([code], mod, file)
Base.getindex(ev::EvalableCode, ind::UnitRange) =
    EvalableCode(ev.code[ind], ev.mod, ev.file)
Base.getindex(ev::EvalableCode, ind::Int) = ev.code[ind]
Base.length(ec::EvalableCode) = length(ec.code)
apply_code!(ec::EvalableCode) = run_code_in(ec.code, ec.mod, ec.file)

""" `CodeUpdate(::Vector{EvalableCode})` is merely a collection of `EvalableCode`.
Support `apply_code!(::CodeUpdate)`, and can be `merge`d together. """
immutable CodeUpdate
    ecs::Vector{EvalableCode}
end
Base.merge(cu1::CodeUpdate, cus::CodeUpdate...) =
    # We could conceivably merge the EvalableCode objects that share the same (mod, file)
    CodeUpdate(mapreduce(cu->cu.ecs, vcat, cu1.ecs, cus))
Base.getindex(cu::CodeUpdate, ind::UnitRange) = CodeUpdate(cu.ecs[ind])
Base.getindex(cu::CodeUpdate, ind::Int) = cu.ecs[ind]
Base.length(cu::CodeUpdate) = length(cu.ecs)
apply_code!(cu::CodeUpdate) = map(apply_code!, cu.ecs)

""" `RevertibleCodeUpdate(apply::CodeUpdate, revert::CodeUpdate)` contains code
to modify a module, and revert it back to its former state. Use `apply_code!` and
`revert_code!`, or `(::RevertibleCodeUpdate)() do ... end` to temporarily apply the code.
"""
immutable RevertibleCodeUpdate
    apply::CodeUpdate
    revert::CodeUpdate
end
EmptyRevertibleCodeUpdate() = RevertibleCodeUpdate(CodeUpdate([]), CodeUpdate([]))
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
    #   OR: get rid of the silly n-tuple generality, and only support 2-tuples
    # Note: Tuple(generator) syntax is 0.6-only
    tuple((merge(cus...)
           for cus in zip((update_code_many(fn, mod, file)
                           for file in gather_all_module_files(string(mod)))...))...)

update_code_many(fn::Function, mod::Module, file::String) =
    tuple((CodeUpdate([EvalableCode(Expr[c for c in newcode if c !== nothing],
                                    mod, file)])
           for newcode in zip([fn(strip_docstring(expr))
                               for expr in parse_file_mod(file, mod)]...))...)

################################################################################
# These should go into MacroTools/ExprTools

function is_function_definition(expr::Expr)
    l = longdef1(expr)
    l.head == :function && length(l.args) > 1 # `function foo end` is not a definition
end
is_function_definition(::Any) = false

""" `get_function(mod::Module, fundef::Expr)::Function` returns the `Function` which this
`fundef` is defining. This code works only when the Function already exists. """
get_function(mod::Module, fundef::Expr)::Union{Function, Type} =
    eval(mod, splitdef(fundef)[:name])

is_call_definition(fundef) = @capture(splitdef(fundef)[:name], (a_::b_) | (::b_))

strip_docstring(x) = x
function strip_docstring(x::Expr)
    if x.head == :macrocall && x.args[1] == GlobalRef(Core, Symbol("@doc"))
        strip_docstring(x.args[3])
    else
        x
    end
end

################################################################################

function revertible_update_helper(fn)
    function (code)
        res = fn(code)
        if res === nothing
            (nothing, nothing)
        else
            (res, code)
        end
    end
end

""" `update_code_revertible(new_code_fn::Function, mod::Module)` applies
the source code transformation function `new_code_fn` to each expression in the source
code of `mod`, and returns a `RevertibleCodeUpdate` which can put into effect/revert
that new code.

IMPORTANT: if some expression `x` should not be modified, return `nothing` instead of `x`.
This will significantly improve performance. """
function update_code_revertible(fn::Function, mod::Module)
    if mod == Base; error("Cannot update all of Base (only specific functions/files)") end
    apply, revert = update_code_many(revertible_update_helper(fn), mod)
    return RevertibleCodeUpdate(apply, revert)
end
function update_code_revertible(fn::Function, mod::Module, file::String)
    apply, revert = update_code_many(revertible_update_helper(fn), mod, file)
    return RevertibleCodeUpdate(apply, revert)
end

function update_code_revertible(new_code_fn::Function, mod::Module,
                                file::String, fn_to_change::Union{Function, Type})
    update_code_revertible(mod, file) do expr
        if (is_function_definition(expr) &&
            !is_call_definition(expr) &&
            get_function(mod, expr) == fn_to_change)
            new_code_fn(expr)
        else nothing end
    end
end

method_file_counts(fn_to_change) =
    counter((mod, file)
            # The Set is so that we count methods that have the same file and line number.
            # (i.e. optional files, although it might catch macroexpansions too; not
            # sure if that's good or not)
            for (mod, file, line) in Set((m.module, functionloc(m)...)
                                         for m in methods(fn_to_change).ms))

immutable UpdateInteractiveFailure
    fn::Union{Function, Type}
end
Base.show(io::IO, upd::UpdateInteractiveFailure) =
    write(io, "Cannot find source of methods defined interactively ($(upd.fn)).")

immutable MissingMethodFailure
    count::Int
    correct_count::Int
    fn::Union{Function, Type}
    file::String
end
Base.show(io::IO, fail::MissingMethodFailure) =
    write(io, "Only $(fail.count)/$(fail.correct_count) methods of $(fail.fn) in $(fail.file) were found.")

""" `update_code_revertible(new_code_fn::Function, fn_to_change::Function)` applies
the source code transformation function `new_code_fn` to the source of each of the
mehods of `fn_to_change`, and returns a `RevertibleCodeUpdate` which can put into
effect/revert that new code. """
function update_code_revertible(new_code_fn::Function,
                                fn_to_change::Union{Function, Type};
                                when_missing=warn)
    if when_missing in (false, nothing); when_missing = _->nothing end
    function update(mod, file, correct_count)
        if mod == Main
            when_missing(UpdateInteractiveFailure(fn_to_change))
            return EmptyRevertibleCodeUpdate()
        end
        rcu = update_code_revertible(new_code_fn, mod, string(file), fn_to_change)
        count = length(only(rcu.revert.ecs)) # how many methods were updated
        if count != correct_count
            when_missing(MissingMethodFailure(count, correct_count, fn_to_change, file))
        end
        rcu
    end
    merge((update(mod, file, correct_count)
           for ((mod, file), correct_count) in method_file_counts(fn_to_change))...)
end

""" `source(fn::Function, when_missing=warn)::Vector` returns a vector of the parsed
code corresponding to each method of `fn`. It can fail for any number of reasons,
and `when_missing` is a function that will be passed an exception when it cannot find
the code.
"""
function source(obj::Union{Module, Function}; kwargs...)
    code = []
    # It's (negligibly) wasteful and ugly to use `update_code_revertible` when all we
    # want is to get the Module's or the Function's definitions, but I doubt that a
    # refactor would be any cleaner. - June'17
    update_code_revertible(obj; kwargs...) do expr
        push!(code, expr)
        :(one(1)) # needs an expr to get correct `length` in update_code_revertible
    end
    code
end
