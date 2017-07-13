# Code that doesn't parse under Julia 0.5
# This is part of fundef.jl

function gather_wheres(ex)
    if @capture(ex, (f_ where {params1__}))
        f2, params2 = gather_wheres(f)
        (f2, (params1..., params2...))
    else
        (ex, ())
    end
end

function longdef1_where(ex)
    if @capture(ex, (fcall_ = body_))
        fcall2, whereparams = gather_wheres(fcall)
        @match fcall2 begin
            (f_(args__)) =>
                @q function $f($(args...)) where {$(whereparams...)}
                    $body end
            (f_(args__)::rtype_) =>
                @q function ($f($(args...))::$rtype) where {$(whereparams...)}
                    $body end
            _ => ex
        end
    else
        ex
    end
end
function splitwhere(fdef)
    @assert(@capture(longdef1(fdef),
                     function (fcall_ | fcall_) body_ end),
            "Not a function definition: $fdef")
    fcall2, whereparams = gather_wheres(fcall)
    return fcall2, body, whereparams
end

"""
     combinedef(dict::Dict)

`combinedef` is the inverse of `splitdef`. It takes a splitdef-like dict
and returns a function definition. """
function combinedef(dict::Dict)
    rtype = get(dict, :rtype, :Any)
    params = get(dict, :params, [])
    # LightGraph.jl has outer-constructors with both normal-params and where-params
    # TODO: write test
    wparams = get(dict, :whereparams, [])
    name = dict[:name]
    name_p = isempty(params) ? name : :($name{$(params...)})
    if isempty(wparams)
        :(function $name_p($(dict[:args]...);
                           $(dict[:kwargs]...))::$rtype
          $(dict[:body])
          end)
    else
        :(function $name_p($(dict[:args]...);
                           $(dict[:kwargs]...))::$rtype where {$(wparams...)}
          $(dict[:body])
          end)
    end
end
