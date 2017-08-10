## Code for removing warnings

export scrub_stderr, scrub_redefinition_warnings, no_warnings, sinclude

# O nameless stranger, please improve my ailing regexes.
redefinition_regexes =
    [r"WARNING: Method definition .* in module .* at .* overwritten at .*\n",
     r"WARNING: Method definition .* in module .* overwritten.\n",
     r"WARNING: replacing docs for .*\n",
     # 0.6 updated its doc warnings with color. Looks like this:
     # \e[1m\e[33mWARNING: \e[39m\e[22m\e[33mreplacing
     r".*WARNING: .*replacing docs for .*\n",
     r"WARNING: redefining constant .*\n"]


""" `scrub_stderr(body::Function, pats::Regex...)` executes `body` without
outputting any warning that matches one of the `pats`.

Pattern example: r"WARNING: redefining constant .*\n" """
function scrub_stderr(body::Function, pats::Regex...)
    mktemp() do _, f
        old_stderr = STDERR
        redirect_stderr(f)
        try
            res = body()
            flush(f)
            seekstart(f)
            text = readstring(f)
            for pat in pats
                text = replace(text, pat, "")
            end
            write(old_stderr, text)
            res
        finally
            redirect_stderr(old_stderr)
        end
    end
end


""" `scrub_redefinition_warnings(body::Function)` executes `body` without
outputting any redefinition warnings """
function scrub_redefinition_warnings(body::Function)
    scrub_stderr(redefinition_regexes...) do
        body()
    end
end


""" `no_warnings(body::Function)` executes `body` without outputting any
warnings (no STDERR output) """
function no_warnings(body::Function)
    scrub_stderr(r".*\n") do
        body()
    end
end


""" `sinclude(filename)` calls `include(filename)`, but doesn't show any 
redefinition warnings (it's a _silent_ `include`) """
function sinclude(filename)
    scrub_redefinition_warnings() do
        include(filename)
    end
end
