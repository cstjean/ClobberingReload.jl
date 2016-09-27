import IJulia

export areload, @ausing, @aimport


hook_registered = false
function register_hook!() # for IJulia
    if !hook_registered
        global hook_registered = true
        IJulia.push_preexecute_hook(areload)
    end
end

# Filename => Set(Modules_That_Include_Filename)
file2mods = Dict{String, Set{String}}() # TODO: const
# Module => Last_Time_It_Was_Loaded
module2time = Dict{String, Number}()

function module_was_loaded!(mod_name)
    module2time[mod_name] = time()
    register_module_files!(mod_name)
end
        

"""    register_module_files!(mod_name::String)

Remembers all the files included by `mod_name` """
function register_module_files!(mod_name::String)
    for fname in gather_all_module_files(mod_name)
        push!(get!(file2mods, fname, Set{String}()), mod_name)
    end
end

""" `modified_modules()::Set{String}()` returns the set of modules that were
modified since last time they were loaded. """
function modified_modules()
    modified_mods = Set{String}()
    for (fname, module_names) in file2mods
        for mod in module_names
            # Was it modified after the last time the module was loaded?
            if mtime(fname) > module2time[mod]
                push!(modified_mods, mod)
            end
        end
    end
    return modified_mods
end


# helper for ausing/aimport
function apost!(mod_sym::Symbol)
    module_was_loaded!(string(mod_sym))
    register_hook!()
    mod_sym
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

""" `@aimport module_name` is like `import module_name`, but the module will be
reloaded automatically (in IJulia) whenever the module has changed. See
ClobberingReload's README for details. """
macro aimport(mod_sym::Symbol)
    esc(:(begin
        import $mod_sym
        $ClobberingReload.apost!($mod_sym)
    end))
end


""" `areload()` reloads (using `creload`) all modules that have been modified
since they were last loaded. Called automatically in IJulia. """
function areload()
    for mod_name in modified_modules()
        creload(mod_name)
    end
end
