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


macro ausing(mod_sym::Symbol)
    # call using
    # register the module file for reloading
    esc(:(begin
        using $mod_sym
        $ClobberingReload.module_was_loaded!($(string(mod_sym)))
        $ClobberingReload.register_hook!()
    end))
end

macro aimport(mod_sym::Symbol)
    # call using
    # register the module file for reloading
    esc(:(begin
        import $mod_sym
        $ClobberingReload.module_was_loaded!($(string(mod_sym)))
        $ClobberingReload.register_hook!()
    end))
end


""" `areload()` reloads (using `creload`) all modules that have been modified
since they were last loaded. """
function areload()
    for mod_name in modified_modules()
        creload(mod_name)
    end
end
