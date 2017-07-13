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
                     function ((fcall_ where {whereparams__}) | fcall_)
                     body_ end),
            "Not a function definition: $fdef")
    return fcall, body, whereparams
end
