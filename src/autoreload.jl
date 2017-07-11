# This code is derived from @malmaud's Autoreload.jl
# It also contains snippets from @MikeInnes's Juno

export areload, @ausing, @aimport

const mod2files = Dict{String, Set{String}}()
# Module => Last_Time_It_Was_Loaded
const module2time = Dict{String, Number}()
const depends_on = Dict{String, Set{String}}()

gather_includes(code::Vector) =
    mapreduce(vcat, vcat(code, [:(1+1)])) do expr
        @match expr begin
            include(fname_) => [fname]
            any_ => []
        end
    end

module_string(mod::String) = mod
module_string(mod::Module) = string(module_name(mod))

module_definition_file_(mod) = Base.find_in_node_path(module_string(mod), nothing, 1)
function module_definition_file(mod)
    path = module_definition_file_(mod)
    if path === nothing
        error("Cannot find path of module $mod. To be usable by `ClobberingReload`, the module has to be defined in a file called $mod.jl, and that file's directory must be pushed onto LOAD_PATH. See the Julia docs on `using`.")
    end
    path
end

"""    gather_all_module_files(mod_name::String)

Given a module name (as a string), returns the list of all files that define
this module (i.e. the module name + all included files, applied recursively).

IMPORTANT: we only return and follow `include("somestring")`. We give up on things like:
`include(joinpath(dirname(@__FILE__), "..", "deps","depsutils.jl"))`
"""
function gather_all_module_files(mod)
    mod_path = module_definition_file(mod)
    included_files = Set{String}([mod_path]) # to be filled
    gather(full_path, parse_fun) = 
        cd(dirname(full_path)) do
            mod_includes = map(abspath,
                               filter(x->isa(x, String),
                                      gather_includes(parse_fun(basename(full_path)))))
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


""" `module_code(mod_name::String)` returns a vector of
`(filename::String, code::Vector)` tuple, for each
module-defining file (i.e. the main module file + all included files). The
tuple with module-defining code excludes the `module module_name` markers, and just
returns the content. """
function module_code(mod)
    main_file = module_definition_file(mod_name)
    [(filename, filename==main_file ? parse_module_file(filename) : parse_file(filename))
     for filename in gather_all_module_files(mod_name)]
end


hook_registered = false
function register_hook!() # for IJulia
    if !hook_registered
        global hook_registered = true
        try
            # This is in order to avoid requiring IJulia.
            # We could also use Requires.jl
            Main.IJulia.push_preexecute_hook(areload)
        end
    end
end

function module_was_loaded!(mod)
    mod_name = module_string(mod)
    module2time[mod_name] = time()
    register_module_files!(mod_name)
    mod_name
end
        

"""    register_module_files!(mod_name::String)

Remembers all the files included by `mod_name` """
function register_module_files!(mod_name::String)
    mod2files[mod_name] = gather_all_module_files(mod_name)
end

""" `is_modified(mod::String)` returns true iff one of its files was modified
"""
is_modified(mod::String) = any(mtime(fname) > module2time[mod]
                               for fname in mod2files[mod])

# helper for ausing/aimport
function apost!(mod::Module, deps=[])
    if isa(deps, Module) deps = [deps] end
    deps = Set{String}(map(string, deps))
    for dep in deps
        @assert(haskey(depends_on, dep),
                "@ausing/@aimport error: $mod depends on $dep, but $dep isn't registered for autoreloading. Write `@ausing $dep` before `@ausing $mod <: ...`")
    end
    depends_on[string(mod)] = deps
    module_was_loaded!(string(mod))
    register_hook!()
    mod
end

""" `@ausing module_name` is like `using module_name`, but the module will be
reloaded automatically (in IJulia) whenever the module has changed. See
ClobberingReload's README for details.

NOTE: `@ausing module_name: a, b, c` is unsupported, but this is equivalent:

```julia
@aimport module_name
using module_name: a, b, c
```
"""
macro ausing(mod_sym::Symbol)
    esc(:(begin
        using $mod_sym
        $ClobberingReload.apost!($mod_sym)
    end))
end

macro ausing(mod_deps::Expr)
    @assert @capture(mod_deps, mod_sym_ <: deps_)
    esc(:(begin
        using $mod_sym
        $ClobberingReload.apost!($mod_sym, $deps)
    end))
end

""" `@aimport module_name` is like `import module_name`, but the module will be
reloaded automatically (in IJulia) whenever the module has changed. See
ClobberingReload's README for details. """
macro aimport(mod_sym::Symbol)
    esc(:(begin
        import $mod_sym
        $ClobberingReload.apost!($mod_sym)
    end))
end

macro aimport(mod_deps::Expr)
    @assert @capture(mod_deps, mod_sym_ <: deps_)
    esc(:(begin
        import $mod_sym
        $ClobberingReload.apost!($mod_sym, $deps)
    end))
end

""" `areload()` reloads (using `creload`) all modules that have been modified
since they were last loaded. Called automatically in IJulia. """
function areload()
    was_reloaded = Dict{String, Bool}()
    function relo(mod_name)
        if haskey(was_reloaded, mod_name)
            return was_reloaded[mod_name]
        else
            # First reload all its dependencies.
            # We have to reload mod_name IFF one of its dependencies is
            # reloaded, or if it's modified itself
            to_rel = any(relo, depends_on[mod_name]) || is_modified(mod_name)
            if to_rel
                creload(mod_name)
            end
            was_reloaded[mod_name] = to_rel
        end
    end
    foreach(relo, keys(depends_on))
end
