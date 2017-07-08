export apply_code!, revert_code!, update_code_revertible, RevertibleCodeUpdate,
    CodeUpdate, EvalableCode, source

immutable EvalableCode
    code::Vector{Expr}
    mod::Module
    file::Union{String, Void}
end
EvalableCode(code::Expr, mod::Module, file) = EvalableCode([code], mod, file)
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
                                file::String, fn_to_change::Function)
    update_code_revertible(mod, file) do expr
        if (is_function_definition(expr) &&
            !is_call_definition(expr) &&
            get_function(mod, expr) == fn_to_change)
            new_code_fn(expr)
        else nothing end
    end
end

function counter(seq)  # could use DataStructures.counter, but it's a big dependency
    di = Dict()
    for x in seq; di[x] = get(di, x, 0) + 1 end
    di
end

method_file_counts(fn_to_change) = counter((m.module, m.file)
                                           for m in methods(fn_to_change).ms)

immutable UpdateInteractiveFailure
    fn::Function
end
Base.show(io::IO, upd::UpdateInteractiveFailure) =
    write(io, "Cannot handle methods of $(upd.fn) defined interactively.")

immutable MissingMethodFailure
    count::Int
    correct_count::Int
    fn::Function
    file::String
end
Base.show(io::IO, fail::MissingMethodFailure) =
    write(io, "Could only find $(fail.count)/$(fail.correct_count) methods of $(fail.fn) in $(fail.file)")

function update_code_revertible(new_code_fn::Function, fn_to_change::Function;
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
